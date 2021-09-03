/********************************************************************************
 * Copyright (c) 2018-2021 Contributors to the Gamma project
 *
 * All rights reserved. This program and the accompanying materials
 * are made available under the terms of the Eclipse Public License v1.0
 * which accompanies this distribution, and is available at
 * http://www.eclipse.org/legal/epl-v10.html
 *
 * SPDX-License-Identifier: EPL-1.0
 ********************************************************************************/
package hu.bme.mit.gamma.xsts.transformation

import hu.bme.mit.gamma.expression.model.ArrayTypeDefinition
import hu.bme.mit.gamma.expression.model.DirectReferenceExpression
import hu.bme.mit.gamma.expression.model.Expression
import hu.bme.mit.gamma.expression.model.ExpressionModelFactory
import hu.bme.mit.gamma.expression.model.TypeReference
import hu.bme.mit.gamma.expression.util.ExpressionEvaluator
import hu.bme.mit.gamma.lowlevel.xsts.transformation.LowlevelToXstsTransformer
import hu.bme.mit.gamma.lowlevel.xsts.transformation.TransitionMerging
import hu.bme.mit.gamma.statechart.composite.AbstractSynchronousCompositeComponent
import hu.bme.mit.gamma.statechart.composite.AsynchronousAdapter
import hu.bme.mit.gamma.statechart.composite.AsynchronousCompositeComponent
import hu.bme.mit.gamma.statechart.composite.CascadeCompositeComponent
import hu.bme.mit.gamma.statechart.composite.ComponentInstance
import hu.bme.mit.gamma.statechart.composite.ControlFunction
import hu.bme.mit.gamma.statechart.composite.DiscardStrategy
import hu.bme.mit.gamma.statechart.composite.MessageQueue
import hu.bme.mit.gamma.statechart.interface_.AnyTrigger
import hu.bme.mit.gamma.statechart.interface_.Component
import hu.bme.mit.gamma.statechart.interface_.Port
import hu.bme.mit.gamma.statechart.lowlevel.model.Package
import hu.bme.mit.gamma.statechart.lowlevel.transformation.GammaToLowlevelTransformer
import hu.bme.mit.gamma.statechart.lowlevel.transformation.Trace
import hu.bme.mit.gamma.statechart.lowlevel.transformation.ValueDeclarationTransformer
import hu.bme.mit.gamma.statechart.statechart.StatechartDefinition
import hu.bme.mit.gamma.util.GammaEcoreUtil
import hu.bme.mit.gamma.util.JavaUtil
import hu.bme.mit.gamma.xsts.model.AbstractAssignmentAction
import hu.bme.mit.gamma.xsts.model.Action
import hu.bme.mit.gamma.xsts.model.CompositeAction
import hu.bme.mit.gamma.xsts.model.InEventGroup
import hu.bme.mit.gamma.xsts.model.RegionGroup
import hu.bme.mit.gamma.xsts.model.XSTS
import hu.bme.mit.gamma.xsts.model.XSTSModelFactory
import hu.bme.mit.gamma.xsts.transformation.util.OrthogonalActionTransformer
import hu.bme.mit.gamma.xsts.util.XstsActionUtil
import java.util.AbstractMap.SimpleEntry
import java.util.Collection
import java.util.List
import java.util.logging.Level
import java.util.logging.Logger

import static com.google.common.base.Preconditions.checkState

import static extension hu.bme.mit.gamma.expression.derivedfeatures.ExpressionModelDerivedFeatures.*
import static extension hu.bme.mit.gamma.statechart.derivedfeatures.StatechartModelDerivedFeatures.*
import static extension hu.bme.mit.gamma.xsts.derivedfeatures.XstsDerivedFeatures.*
import static extension hu.bme.mit.gamma.xsts.transformation.util.Namings.*
import static extension hu.bme.mit.gamma.xsts.transformation.util.QueueNamings.*
import static extension java.lang.Math.*

class ComponentTransformer {
	// This gammaToLowlevelTransformer must be the same during this transformation cycle due to tracing
	protected final GammaToLowlevelTransformer gammaToLowlevelTransformer
	protected final MessageQueueTraceability queueTraceability
	// Transformation settings
	protected final boolean transformOrthogonalActions
	protected final boolean optimize
	protected final boolean useHavocActions
	protected final boolean extractGuards
	protected final TransitionMerging transitionMerging
	// Auxiliary objects
	protected final extension GammaEcoreUtil ecoreUtil = GammaEcoreUtil.INSTANCE
	protected final extension JavaUtil javaUtil = JavaUtil.INSTANCE
	protected final extension ExpressionEvaluator expressionEvaluator = ExpressionEvaluator.INSTANCE
	protected final extension EnvironmentalActionFilter environmentalActionFilter =
			EnvironmentalActionFilter.INSTANCE
	protected final extension OrthogonalActionTransformer orthogonalActionTransformer =
			OrthogonalActionTransformer.INSTANCE
	protected final extension EventConnector eventConnector = EventConnector.INSTANCE
	protected final extension SystemReducer systemReducer = SystemReducer.INSTANCE
	protected final extension ExpressionModelFactory expressionModelFactory = ExpressionModelFactory.eINSTANCE
	protected final extension XSTSModelFactory xStsModelFactory = XSTSModelFactory.eINSTANCE
	protected final extension XstsActionUtil xStsActionUtil = XstsActionUtil.INSTANCE
	// Logger
	protected final Logger logger = Logger.getLogger("GammaLogger")
	
	new(GammaToLowlevelTransformer gammaToLowlevelTransformer, boolean transformOrthogonalActions,
			boolean optimize, boolean useHavocActions, boolean extractGuards,
			TransitionMerging transitionMerging) {
		this.gammaToLowlevelTransformer = gammaToLowlevelTransformer
		this.transformOrthogonalActions = transformOrthogonalActions
		this.optimize = optimize
		this.useHavocActions = useHavocActions // TODO eliminate havoc
		this.extractGuards = extractGuards
		this.transitionMerging = transitionMerging
		this.queueTraceability = new MessageQueueTraceability
	}
	
	def dispatch XSTS transform(Component component, Package lowlevelPackage) {
		throw new IllegalArgumentException("Not supported component type: " + component)
	}
	
	// TODO move most parts into the AA transformer and make sure in preprocess AAs are not top components
	def dispatch XSTS transform(AsynchronousCompositeComponent component, Package lowlevelPackage) {
		val systemPorts = component.allPorts
		// Parameters of all asynchronous composite components
		component.extractAllParameters
		// Retrieving the adapter instances - hierarchy does not matter here apart from the order
		val adapterInstances = component.allAsynchronousSimpleInstances
		val environmentalQueues = newHashSet
		
		val name = component.name
		val xSts = name.createXsts
		
		val eventReferenceMapper = new EventReferenceToXstsVariableMapper(xSts)
		val valueDeclarationTransformer = new ValueDeclarationTransformer
		val variableTrace = valueDeclarationTransformer.getTrace
		
		val variableInitAction = createSequentialAction
		val configInitAction = createSequentialAction
		val entryAction = createSequentialAction
		
		val inEventAction = createSequentialAction
		val outEventAction = createSequentialAction
		
		val mergedAction = createSequentialAction
		
		// Transforming and saving the adapter instances
		
		val mergedActions = newHashMap
		for (adapterInstance : adapterInstances) {
			val adapterComponentType = adapterInstance.type as AsynchronousAdapter
			
			adapterComponentType.extractParameters(adapterInstance.arguments) // Parameters
			val adapterXsts = adapterComponentType.transform(lowlevelPackage)
			xSts.merge(adapterXsts) // Adding variables, types, etc.
			
			variableInitAction.actions += adapterXsts.variableInitializingTransition.action
			configInitAction.actions += adapterXsts.configurationInitializingTransition.action
			entryAction.actions += adapterXsts.entryEventTransition.action
			
			mergedActions += adapterInstance -> adapterXsts.mergedAction
			
			// inEventActions later
			// Filtering events can be used (internal ones and ones led out to the environment)
			outEventAction.actions += adapterXsts.outEventTransition.action
		}
		
		// Creating the message queue constructions
		
		for (adapterInstance : adapterInstances) {
			val adapterComponentType = adapterInstance.type as AsynchronousAdapter
			for (queue : adapterComponentType.messageQueues) {
				if (queue.isEnvironmentalAndCheck(systemPorts)) {
					environmentalQueues += queue // Tracing
				}
				
				val storedPortEvents = newHashSet
				val events = queue.storedEvents
				for (event : events) {
					val id = queue.getEventId(event) // Id is needed during back-annotation
					queueTraceability.put(event, id)
					storedPortEvents += event
					logger.log(Level.INFO, '''Assigning «id» to «event.key.name».«event.value.name»''')
				}
				
				val evaluatedCapacity = queue.getCapacity(systemPorts)
				val masterQueueType = createArrayTypeDefinition => [
					it.elementType = createIntegerTypeDefinition
					it.size = evaluatedCapacity.toIntegerLiteral
				]
				val masterQueueName = queue.getMasterQueueName(adapterInstance)
				val masterQueue = masterQueueType.createVariableDeclaration(masterQueueName)
				
				val masterSizeVariableName = queue.getMasterSizeVariableName(adapterInstance)
				val masterSizeVariable = createIntegerTypeDefinition
						.createVariableDeclaration(masterSizeVariableName)
				
				val slaveQueuesMap = newHashMap
				for (portEvent : events) {
					val port = portEvent.key
					val event = portEvent.value
					val List<MessageQueueStruct> slaveQueues = newArrayList
					// Important optimization - we create a queue only if the event is used
					if (eventReferenceMapper.hasInputEventVariable(event, port)) {
						for (parameter : event.parameterDeclarations) {
							val parameterType = parameter.type
							val slaveQueueType = createArrayTypeDefinition => [
								it.elementType = parameterType.clone
								it.size = evaluatedCapacity.toIntegerLiteral
							]
							val slaveQueueName = parameter.getSlaveQueueName(port, adapterInstance)
							val slaveQueue = slaveQueueType.createVariableDeclaration(slaveQueueName)
							
							val slaveSizeVariableName = parameter.getSlaveSizeVariableName(port, adapterInstance)
							val slaveSizeVariable = createIntegerTypeDefinition
									.createVariableDeclaration(slaveSizeVariableName)
							
							slaveQueues += new MessageQueueStruct(slaveQueue, slaveSizeVariable)
						}
					} // If no input event variable - slaveQueues is empty
					slaveQueuesMap += portEvent -> slaveQueues
				}
				
				val messageQueueMapping = new MessageQueueMapping(storedPortEvents,
						new MessageQueueStruct(masterQueue, masterSizeVariable), slaveQueuesMap)
				queueTraceability.put(queue, messageQueueMapping)
				val slaveQueues = messageQueueMapping.slaveQueues
			
				// Transforming the message queue constructions into native XSTS variables
				// We do not care about the names (renaming) here
				// Namings.customize* covers the same naming behavior as QueueNamings + valueDeclarationTransformer
				
				xSts.variableDeclarations += valueDeclarationTransformer.transform(masterQueue)
				xSts.variableDeclarations += valueDeclarationTransformer.transform(masterSizeVariable)
				for (slaveQueueStructs : slaveQueues.values) {
					for (slaveQueueStruct : slaveQueueStructs) {
						val slaveQueue = slaveQueueStruct.arrayVariable
						val slaveSizeVariable = slaveQueueStruct.sizeVariable
						xSts.variableDeclarations += valueDeclarationTransformer.transform(slaveQueue)
						xSts.variableDeclarations += valueDeclarationTransformer.transform(slaveSizeVariable)
						// The type might not be correct here and later has to be reassigned to handle enums
					}
				}
			}
		}
		
		// Creating queue process behavior
		
		val executionList = adapterInstances // In the future, one instance could be executed multiple times
		for (adapterInstance : executionList) {
			val adapterComponentType = adapterInstance.type as AsynchronousAdapter
			val originalMergedAction = mergedActions.get(adapterInstance)
			// Input event processing
			for (queue : adapterComponentType.messageQueues) {
				val queueMapping = queueTraceability.get(queue)
				val masterQueue = queueMapping.masterQueue.arrayVariable
				val masterSizeVariable = queueMapping.masterQueue.sizeVariable
				val slaveQueues = queueMapping.slaveQueues
				
				// Actually, the following values are "low-level values", but we handle them as XSTS values
				val xStsMasterQueue = variableTrace.getAll(masterQueue).onlyElement
				val xStsMasterSizeVariable = variableTrace.getAll(masterSizeVariable).onlyElement
				
				val block = createSequentialAction
				
				val messageRetrievalCount = queue.checkAndGetMessageRetrievalCount // TODO check
				switch (messageRetrievalCount) {
					case ONE:
						mergedAction.actions += block
					case ALL: {
						val queueLoop = loopIterationVariableName.createLoopAction(
								0.toIntegerLiteral, xStsMasterSizeVariable.createReferenceExpression) => [
							it.action = block
						]
						mergedAction.actions += queueLoop
					}
					default:
						throw new IllegalArgumentException("Not known literal: " + messageRetrievalCount)
				}
				
				val xStsEventIdVariableAction = createIntegerTypeDefinition.createVariableDeclarationAction(
						xStsMasterQueue.eventIdLocalVariableName, xStsMasterQueue.peek)
				val xStsEventIdVariable = xStsEventIdVariableAction.variableDeclaration
				block.actions += xStsEventIdVariableAction
				block.actions += xStsMasterQueue.popAndDecrement(xStsMasterSizeVariable)
				
				// Processing the possible different event identifiers
				
				val branchExpressions = <Expression>newArrayList
				val branchActions = <Action>newArrayList
				
				val emptyValue = xStsMasterQueue.arrayElementType.defaultExpression
				// if (eventId == 0) { empty }
				branchExpressions += xStsEventIdVariable.createEqualityExpression(emptyValue)
				branchActions += createEmptyAction
				
				val events = queue.storedEvents
				for (portEvent : events) {
					val port = portEvent.key
					val event = portEvent.value
					val eventId = queueTraceability.get(portEvent)
					
					// Can be empty due to optimization or adapter event
					val xStsInEventVariables = eventReferenceMapper.getInputEventVariables(event, port)
					
					val ifExpression = xStsEventIdVariable.createReferenceExpression
							.createEqualityExpression(eventId.toIntegerLiteral)
					val thenAction = createSequentialAction
					// Setting the event variables to true (multiple binding is possible)
					for (xStsInEventVariable : xStsInEventVariables) {
						thenAction.actions += xStsInEventVariable.createAssignmentAction(
								createTrueExpression)
					}
					// Setting the parameter variables with values stored in slave queues
					val slaveQueueStructs = slaveQueues.get(portEvent) // Might be empty
					
					val parameters = event.parameterDeclarations
					val slaveQueueSize = slaveQueueStructs.size // Might be 0 if there is no in-event var
					for (var i = 0; i < slaveQueueSize; i++) {
						val slaveQueueStruct = slaveQueueStructs.get(i)
						val slaveQueue = slaveQueueStruct.arrayVariable
						val slaveSizeVariable = slaveQueueStruct.sizeVariable
						val inParameter = parameters.get(i)
						
						val xStsSlaveQueues = variableTrace.getAll(slaveQueue)
						val xStsSlaveSizeVariable = variableTrace.getAll(slaveSizeVariable).onlyElement
						val xStsInParameterVariableLists = eventReferenceMapper
								.getInputParameterVariablesByPorts(inParameter, port)
						// Separated in the lists according to ports
						for (xStsInParameterVariables : xStsInParameterVariableLists) {
							// Parameter optimization problem: parameters are not deleted independently
							val size = xStsInParameterVariables.size 
							for (var j = 0; j < size; j++) {
								val xStsInParameterVariable = xStsInParameterVariables.get(j)
								val xStsSlaveQueue = xStsSlaveQueues.get(j)
								// Setting type to prevent enum problems (multiple times, though, not a problem)
								val xStsSlaveQueueType = xStsSlaveQueue.typeDefinition as ArrayTypeDefinition
								xStsSlaveQueueType.elementType = xStsInParameterVariable.type.clone
								//
								thenAction.actions += xStsInParameterVariable
										.createAssignmentAction(xStsSlaveQueue.peek)
							}
						}
						thenAction.actions += xStsSlaveQueues.popAllAndDecrement(xStsSlaveSizeVariable)
					}
					// Execution if necessary
					if (adapterComponentType.isControlSpecification(portEvent)) {
						thenAction.actions += originalMergedAction.clone
					}
					// if (eventId == ..) { "transfer slave queue values" if (isControlSpec) { "run" }
					branchExpressions += ifExpression
					branchActions += thenAction
				}
				// Excluding branches for the different event identifiers
				block.actions += branchExpressions.createChoiceAction(branchActions)
			}
			
			// Dispatching events to connected message queues
			for (port : adapterComponentType.allPorts) {
				// Semantical question: now out events are dispatched according to this order
				val eventDispatchAction = port.createEventDispatchAction(
						eventReferenceMapper, systemPorts, variableTrace)
				mergedAction.actions += eventDispatchAction.clone
				entryAction.actions += eventDispatchAction // Same for initial action
			}
		}
		
		// Initializing message queue related variables - done here and not initial expression
		// as the potential enumeration type declarations of slave queues there are not traced
		
		val xStsQueueVariables = newArrayList
		for (queueStruct : queueTraceability.allQueues) {
			val queue = queueStruct.arrayVariable
			val sizeVariable = queueStruct.sizeVariable
			xStsQueueVariables += variableTrace.getAll(queue)
			xStsQueueVariables += variableTrace.getAll(sizeVariable)
		}
		for (xStsQueueVariable : xStsQueueVariables) {
			variableInitAction.actions += xStsQueueVariable.createVariableResetAction
		}
		
		//
		
		xSts.variableInitializingTransition = variableInitAction.wrap
		xSts.configurationInitializingTransition = configInitAction.wrap
		xSts.entryEventTransition = entryAction.wrap
		
		// Creating environment behavior
		
		val systemEvents = newHashSet
		for (systemAsynchronousSimplePort : component.allBoundAsynchronousSimplePorts) {
			for (inEvent : systemAsynchronousSimplePort.inputEvents) {
				val portEvent = new SimpleEntry(systemAsynchronousSimplePort, inEvent)
				if (queueTraceability.contains(portEvent)) {
					logger.log(Level.INFO,
						'''Found «systemAsynchronousSimplePort.name».«inEvent.name» as system input event''')
					systemEvents += portEvent
				}
			}
		}
		for (queue : environmentalQueues) { // All with capacity 1 and size 0
			if (useHavocActions) {
				val queueMapping = queueTraceability.get(queue)
				val masterQueue = queueMapping.masterQueue.arrayVariable
				val masterSizeVariable = queueMapping.masterQueue.sizeVariable
				val slaveQueues = queueMapping.slaveQueues
				
				val xStsMasterQueue = variableTrace.getAll(masterQueue).onlyElement
				val xStsMasterSizeVariable = variableTrace.getAll(masterSizeVariable).onlyElement
				
				val xStsEventIdVariableAction = xStsMasterQueue
					.createVariableDeclarationActionForArray(
						xStsMasterQueue.eventIdLocalVariableName)
				val xStsEventIdVariable = xStsEventIdVariableAction.variableDeclaration
				inEventAction.actions += xStsEventIdVariableAction
				inEventAction.actions += xStsEventIdVariable.createHavocAction
				
				// If the id is not an "empty" event
				val emptyValue = xStsEventIdVariable.defaultExpression
				val isNotEmptyExpression = xStsEventIdVariable.createInequalityExpression(emptyValue)
				val setQueuesAction = createSequentialAction
				setQueuesAction.actions += xStsMasterQueue.addAndIncrement( // Or could be used 0 literals for index
						xStsMasterSizeVariable, xStsEventIdVariable.createReferenceExpression)
				
				inEventAction.actions += isNotEmptyExpression.createIfAction(setQueuesAction)
				
				val branchExpressions = <Expression>newArrayList
				val branchActions = <Action>newArrayList
				for (portEvent : slaveQueues.keySet
							.filter[systemEvents.contains(it) /*Only system events*/]) {
					val slaveQueueStructs = slaveQueues.get(portEvent)
					val eventId = queueTraceability.get(portEvent)
					branchExpressions += xStsEventIdVariable
							.createEqualityExpression(eventId.toIntegerLiteral)
					val slaveQueueSetting = createSequentialAction
					branchActions += slaveQueueSetting
					
					for (slaveQueueStruct : slaveQueueStructs) {
						val slaveQueue = slaveQueueStruct.arrayVariable
						val slaveSizeVariable = slaveQueueStruct.sizeVariable
						
						val xStsSlaveQueues = variableTrace.getAll(slaveQueue)
						val xStsSlaveSizeVariable = variableTrace.getAll(slaveSizeVariable).onlyElement
						
						for (xStsSlaveQueue : xStsSlaveQueues) {
							val xStsRandomVariableAction = xStsSlaveQueue
								.createVariableDeclarationActionForArray(
									xStsSlaveQueue.randomValueLocalVariableName)
							val xStsRandomVariable = xStsRandomVariableAction.variableDeclaration
							slaveQueueSetting.actions += xStsRandomVariableAction
							slaveQueueSetting.actions += xStsRandomVariable.createHavocAction
							slaveQueueSetting.actions += xStsSlaveQueue.add(
								0.toIntegerLiteral,	xStsRandomVariable.createReferenceExpression)
						}
						slaveQueueSetting.actions += xStsSlaveSizeVariable.increment
					}
				}
				setQueuesAction.actions += branchExpressions.createChoiceAction(branchActions)
			}
			else {
				throw new IllegalAccessException("Currently, only havoc actions are supported")
			}
		}
		xSts.inEventTransition = inEventAction.wrap
		xSts.outEventTransition = outEventAction.wrap
		
		xSts.changeTransitions(mergedAction.wrap)
		
		//
		
		return xSts
	}
	
	protected def createEventDispatchAction(Port port,
			EventReferenceToXstsVariableMapper eventReferenceMapper,
			Collection<? extends Port> systemPorts, Trace variableTrace) {
		val eventDispatchAction = createSequentialAction
		for (event : port.outputEvents) {
			// Output is unidirectional
			val xStsOutEventVariable = eventReferenceMapper.getOutputEventVariable(event, port)
			
			val ifExpression = xStsOutEventVariable.createReferenceExpression
			val thenAction = createSequentialAction
			
			val connectedAdapterPorts = port.allConnectedAsynchronousSimplePorts
			for (connectedAdapterPort : connectedAdapterPorts) {
				val connectedPortEvent = new SimpleEntry(connectedAdapterPort, event)
				if (queueTraceability.contains(connectedPortEvent)) {
					// The event is stored and not been removed due to optimization
					val eventId = queueTraceability.get(connectedPortEvent)
					// Highest priority in the case of multiple queues allowing storage 
					val queueTrace = queueTraceability.getMessageQueues(connectedPortEvent)
					val originalQueue = queueTrace.key
					val capacity = originalQueue.getCapacity(systemPorts)
					val eventDiscardStrategy = originalQueue.eventDiscardStrategy
					val queueMapping = queueTrace.value
					
					val masterQueueStruct = queueMapping.masterQueue
					val masterQueue = masterQueueStruct.arrayVariable
					val masterSizeVariable = masterQueueStruct.sizeVariable
					val slaveQueues = queueMapping.slaveQueues.get(connectedPortEvent)
					
					val xStsMasterQueue = variableTrace.getAll(masterQueue).onlyElement
					val xStsMasterSizeVariable = variableTrace.getAll(masterSizeVariable).onlyElement
					
					// Expressions and actions that are used in every queue behavior
					val evaluatedCapacity = capacity.toIntegerLiteral
					val hasFreeCapacityExpression = createLessExpression => [
						it.leftOperand = xStsMasterSizeVariable.createReferenceExpression
						it.rightOperand = evaluatedCapacity
					]
					val block = createSequentialAction
					// Master
					block.actions += xStsMasterQueue.addAndIncrement(
							xStsMasterSizeVariable, eventId.toIntegerLiteral)
					// Resetting out event variable if it is not broadcast and led out to the system
					val systemPort = systemPorts.contains(connectedAdapterPort.boundTopComponentPort)
					if (!systemPort) {
						block.actions += xStsOutEventVariable.createVariableResetAction
					}
					// Slaves
					val parameters = event.parameterDeclarations
					val slaveQueueSize = slaveQueues.size // Might be 0 if there is no in-event var
					for (var i = 0; i < slaveQueueSize; i++) {
						val parameter = parameters.get(i)
						val slaveQueueStruct = slaveQueues.get(i)
						val slaveQueue = slaveQueueStruct.arrayVariable
						val slaveSizeVariable = slaveQueueStruct.sizeVariable
						val xStsSlaveQueues = variableTrace.getAll(slaveQueue)
						val xStsSlaveSizeVariable = variableTrace.getAll(slaveSizeVariable).onlyElement
						// Output is unidirectional
						val xStsOutParameterVariables = eventReferenceMapper
								.getOutputParameterVariables(parameter, port)
						// Parameter optimization problem: parameters are not deleted independently
						block.actions += xStsSlaveQueues.addAllAndIncrement(xStsSlaveSizeVariable,
								xStsOutParameterVariables.map[it.createReferenceExpression])
						// Resetting out parameter variables if they are not broadcast and led out to the system
						if (!systemPort) {
							block.actions += xStsOutParameterVariables.map[it.createVariableResetAction]
						}
					}
					
					if (eventDiscardStrategy == DiscardStrategy.INCOMING) {
						// if (size < capacity) { "add elements into master and slave queues" }
						thenAction.actions += hasFreeCapacityExpression.createIfAction(block)
					}
					else if (eventDiscardStrategy == DiscardStrategy.OLDEST) {
						val popActions = createSequentialAction
						popActions.actions += xStsMasterQueue.popAndDecrement(xStsMasterSizeVariable)
						for (slaveQueueStruct : slaveQueues) {
							val slaveQueue = slaveQueueStruct.arrayVariable
							val slaveSizeVariable = slaveQueueStruct.sizeVariable
							val xStsSlaveQueues = variableTrace.getAll(slaveQueue)
							val xStsSlaveSizeVariable = variableTrace.getAll(slaveSizeVariable).onlyElement
							popActions.actions += xStsSlaveQueues.popAllAndDecrement(xStsSlaveSizeVariable)
						}
						// if ((!(size < capacity)) { "pop" }
						// "add elements into master and slave queues"
						thenAction.actions += hasFreeCapacityExpression.createNotExpression
								.createIfAction(popActions)
						thenAction.actions += block
					}
					else {
						throw new IllegalStateException("Not known behavior: " + eventDiscardStrategy)
					}
				}
			}
			// if (inEvent) { "add elements into master and slave queues" }
			eventDispatchAction.actions += ifExpression.createIfAction(thenAction)
		}
		return eventDispatchAction
	}
	
	def dispatch XSTS transform(AsynchronousAdapter component, Package lowlevelPackage) {
		val isTopInPackage = component.topInPackage
		if (isTopInPackage) {
			component.checkAdapter
		}
		
		val wrappedInstance = component.wrappedComponent
		val wrappedType = wrappedInstance.type
		
		val messageQueue = component.messageQueues.head
		
		wrappedType.extractParameters(wrappedInstance.arguments) 
		val xSts = wrappedType.transform(lowlevelPackage)
		
		if (isTopInPackage) {
			val inEventAction = xSts.inEventTransition
			// Deleting synchronous event assignments
			val xStsSynchronousInEventVariables = xSts.variableGroups
				.filter[it.annotation instanceof InEventGroup].map[it.variables]
				.flatten // There are more than one
			for (xStsAssignment : inEventAction.getAllContentsOfType(AbstractAssignmentAction)) {
				val xStsReference = xStsAssignment.lhs as DirectReferenceExpression
				val xStsDeclaration = xStsReference.declaration
				if (xStsSynchronousInEventVariables.contains(xStsDeclaration)) {
					xStsAssignment.remove // Deleting in-event bool flags
				}
			}
			
			val extension eventRef = new EventReferenceToXstsVariableMapper(xSts)
			// Collecting the referenced event variables
			val xStsReferencedEventVariables = newHashSet
			for (eventReference : messageQueue.eventReference) {
				xStsReferencedEventVariables += eventReference.variables
			}
			
			val newInEventAction = createSequentialAction
			// Setting the referenced event variables to false
			for (xStsEventVariable : xStsReferencedEventVariables) {
				newInEventAction.actions += xStsEventVariable
						.createAssignmentAction(createFalseExpression)
			}
			// Enabling the setting of the referenced event variables to true if no other is set
			for (xStsEventVariable : xStsReferencedEventVariables) {
				val negatedVariables = newArrayList
				negatedVariables += xStsReferencedEventVariables
				negatedVariables -= xStsEventVariable
				val branch = createIfActionBranch(
					xStsActionUtil.connectThroughNegations(negatedVariables),
					xStsEventVariable.createAssignmentAction(createTrueExpression)
				)
				branch.extendChoiceWithBranch(createTrueExpression, createEmptyAction)
				newInEventAction.actions += branch
			}
			// Binding event variables that come from the same ports
			newInEventAction.actions += xSts.createEventAssignmentsBoundToTheSameSystemPort(wrappedType)
			 // Original parameter settings
			newInEventAction.actions += inEventAction.action
			// Binding parameter variables that come from the same ports
			newInEventAction.actions += xSts.createParameterAssignmentsBoundToTheSameSystemPort(wrappedType)
			xSts.inEventTransition = newInEventAction.wrap
		}
		return xSts
	}
	
	def dispatch XSTS transform(AbstractSynchronousCompositeComponent component, Package lowlevelPackage) {
		val name = component.name
		logger.log(Level.INFO, "Transforming abstract synchronous composite " + name)
		val xSts = name.createXsts
		val componentMergedActions = <Component, Action>newHashMap // To handle multiple schedulings in CascadeCompositeComponents
		val components = component.components
		
		if (components.empty) {
			logger.log(Level.WARNING, "No components in abstract synchronous composite " + name)
			return xSts
		}
		
		// Input, output and tracing merged actions
		for (var i = 0; i < components.size; i++) {
			val subcomponent = components.get(i)
			val componentType = subcomponent.type
			
			// Normal transformation
			componentType.extractParameters(subcomponent.arguments) // Change the reference from parameters to constants
			val newXSts = componentType.transform(lowlevelPackage)
			newXSts.customizeDeclarationNames(subcomponent)
			
			// Adding new elements
			xSts.merge(newXSts)
			
			// Initializing action
			val variableInitAction = createSequentialAction
			variableInitAction.actions += xSts.variableInitializingTransition.action
			variableInitAction.actions += newXSts.variableInitializingTransition.action
			xSts.variableInitializingTransition = variableInitAction.wrap
			val configInitAction = createSequentialAction
			configInitAction.actions += xSts.configurationInitializingTransition.action
			configInitAction.actions += newXSts.configurationInitializingTransition.action
			xSts.configurationInitializingTransition = configInitAction.wrap
			val entryAction = createSequentialAction
			entryAction.actions += xSts.entryEventTransition.action
			entryAction.actions += newXSts.entryEventTransition.action
			xSts.entryEventTransition = entryAction.wrap
			
			// Merged action
			val actualComponentMergedAction = createSequentialAction => [
				it.actions += newXSts.mergedAction
			]
			// In and Out actions - using sequential actions to make sure they are composite actions
			// Methods reset... and delete... require this
			val newInEventAction = createSequentialAction => [ it.actions += newXSts.inEventTransition.action ]
			newXSts.inEventTransition = newInEventAction.wrap
			val newOutEventAction = createSequentialAction => [ it.actions += newXSts.outEventTransition.action ]
			newXSts.outEventTransition = newOutEventAction.wrap
			// Resetting channel events
			// 1) the Sync ort semantics: Resetting channel IN events AFTER schedule would result in a deadlock
			// 2) the Casc semantics: Resetting channel OUT events BEFORE schedule would delete in events of subsequent components
			// Note, System in and out events are reset in the env action
			if (component instanceof CascadeCompositeComponent) {
				// Resetting IN events AFTER schedule
				val clonedNewInEventAction = newInEventAction.clone
						.resetEverythingExceptPersistentParameters(componentType) // Clone is important
				actualComponentMergedAction.actions += clonedNewInEventAction // Putting the new action AFTER
			}
			else {
				// Resetting OUT events BEFORE schedule
				val clonedNewOutEventAction = newOutEventAction.clone // Clone is important
						.resetEverythingExceptPersistentParameters(componentType)
				actualComponentMergedAction.actions.add(0, clonedNewOutEventAction) // Putting the new action BEFORE
			}
			// In event
			newInEventAction.deleteEverythingExceptSystemEventsAndParameters(component)
			if (xSts !== newXSts) { // Only if this is not the first component
				val inEventAction = createSequentialAction
				inEventAction.actions += xSts.inEventTransition.action
				inEventAction.actions += newInEventAction
				xSts.inEventTransition = inEventAction.wrap
			}
			// Out event
			newOutEventAction.deleteEverythingExceptSystemEventsAndParameters(component)
			if (xSts !== newXSts) { // Only if this is not the first component
				val outEventAction = createSequentialAction
				outEventAction.actions += xSts.outEventTransition.action
				outEventAction.actions += newOutEventAction
				xSts.outEventTransition = outEventAction.wrap
			}
			// Tracing merged action
			componentMergedActions.put(componentType, actualComponentMergedAction.clone)
		}
		
		// Merged action based on scheduling instances
		val scheduledInstances = component.scheduledInstances
		val mergedAction = (component instanceof CascadeCompositeComponent) ?
				createSequentialAction : createOrthogonalAction
		for (var i = 0; i < scheduledInstances.size; i++) {
			val subcomponent = scheduledInstances.get(i)
			val componentType = subcomponent.type
			checkState(componentMergedActions.containsKey(componentType))
			mergedAction.actions += componentMergedActions.get(componentType).clone
		}
		xSts.changeTransitions(mergedAction.wrap)
		
		logger.log(Level.INFO, "Deleting unused instance ports in " + name)
		xSts.deleteUnusedPorts(component) // Deleting variable assignments for unused ports
		// Connect only after xSts.mergedTransition.action = mergedAction
		logger.log(Level.INFO, "Connecting events through channels in " + name)
		xSts.connectEventsThroughChannels(component) // Event (variable setting) connecting across channels
		logger.log(Level.INFO, "Binding event to system port events in " + name)
		val oldInEventAction = xSts.inEventTransition.action
		val bindingAssignments = xSts.createEventAndParameterAssignmentsBoundToTheSameSystemPort(component)
		// Optimization: removing old NonDeterministicActions 
		bindingAssignments.removeNonDeterministicActionsReferencingAssignedVariables(oldInEventAction)
		val newInEventAction = createSequentialAction => [
			it.actions += oldInEventAction
			// Bind together ports connected to the same system port
			it.actions += bindingAssignments
		]
		xSts.inEventTransition = newInEventAction.wrap
		
		if (transformOrthogonalActions) {
			// After connectEventsThroughChannels
			logger.log(Level.INFO, "Transforming orthogonal actions in XSTS " + name)
			xSts.mergedAction.transform(xSts)
			// Before optimize actions
		}
		
		if (optimize) {
			// Optimization: system in events (but not PERSISTENT parameters) can be reset after the merged transition
			xSts.resetInEventsAfterMergedAction(component)
		}
		
		return xSts
	}
	
	def dispatch XSTS transform(StatechartDefinition statechart, Package lowlevelPackage) {
		logger.log(Level.INFO, "Transforming statechart " + statechart.name)
		// Note that the package is already transformed and traced because of the "val lowlevelPackage = gammaToLowlevelTransformer.transform(_package)" call
		val lowlevelStatechart = gammaToLowlevelTransformer.transform(statechart)
		lowlevelPackage.components += lowlevelStatechart
		val lowlevelToXSTSTransformer = new LowlevelToXstsTransformer(
			lowlevelPackage, optimize, useHavocActions, extractGuards, transitionMerging)
		val xStsEntry = lowlevelToXSTSTransformer.execute
		lowlevelPackage.components -= lowlevelStatechart // So that next time the matches do not return elements from this statechart
		val xSts = xStsEntry.key
		// 0-ing all variable declaration initial expression, the normal ones are in the init action
		for (variable : xSts.variableDeclarations) {
			variable.expression = variable.defaultExpression
		}
		return xSts
	}
	
	// Utils
	
	private def void extractAllParameters(AsynchronousCompositeComponent component) {
		for (instance : component.components) {
			val arguments = instance.arguments
			val type = instance.type
			type.extractParameters(arguments)
			if (type instanceof AsynchronousCompositeComponent) {
				type.extractAllParameters
			}
		}
	}
	
	private def extractParameters(Component component, List<Expression> arguments) {
		val _package = component.containingPackage
		val parameters = newArrayList
		parameters += component.parameterDeclarations // So delete does not mess the list up
		// Theta back-annotation retrieves the argument values from the constant list
		
		_package.constantDeclarations += parameters.extractParamaters(
				parameters.map['''_«it.name»_«it.hashCode.abs»'''], arguments)
		
		// Deleting after the index settings have been completed (otherwise the index always returns 0)
		parameters.deleteAll
	}
	
	private def checkAdapter(AsynchronousAdapter component) {
		val messageQueues = component.messageQueues
		checkState(messageQueues.size == 1)
		// The capacity (and priority) do not matter, as they are from the environment
		checkState(component.clocks.empty)
		val controlSpecifications = component.controlSpecifications
		checkState(controlSpecifications.size == 1)
		val controlSpecification = controlSpecifications.head
		val trigger = controlSpecification.trigger
		checkState(trigger instanceof AnyTrigger)
		val controlFunction = controlSpecification.controlFunction
		checkState(controlFunction == ControlFunction.RUN_ONCE)
	}
	
	private def getCapacity(MessageQueue queue, Collection<? extends Port> systemPorts) {
		if (queue.isEnvironmentalAndCheck(systemPorts)) {
			if (queue.messageRetrievalCount == MessageRetrievalCount.ONE) {
				return 1
			}
		}
		val capacity = queue.capacity
		return capacity.evaluateInteger
	}
	
	private def isEnvironmentalAndCheck(MessageQueue queue, Collection<? extends Port> systemPorts) {
		val portEvents = queue.storedEvents
		val ports = portEvents.map[it.key]
		val topPorts = ports.map[it.boundTopComponentPort]
		if (queue.isEnvironmental(systemPorts)) {
			return true // All events are system events
		}
		val capacity = queue.capacity.evaluateInteger
		if (systemPorts.containsOne(topPorts) && capacity == 1) {
			return true // Contains other events too, but the queue will always be empty when using it in the in-event action 
			// TODO except if the initial action raises some internal events 
		}
		checkState(systemPorts.containsNone(topPorts) || capacity == 1,
				"All or none of the ports must be system ports or the capacity must be one")
		return false
	}
	
	private def checkAndGetMessageRetrievalCount(MessageQueue queue) {
		return MessageRetrievalCount.ONE // Makes sense only if the trigger is 'any'
	}
	
	private def void resetInEventsAfterMergedAction(XSTS xSts, Component type) {
		val inEventAction = xSts.inEventTransition.action
		// Maybe still not perfect?
		if (inEventAction instanceof CompositeAction) {
			val clonedInEventAction = inEventAction.clone
			// Not PERSISTENT parameters
			val resetAction = clonedInEventAction.resetEverythingExceptPersistentParameters(type)
			val mergedAction = xSts.mergedAction
			mergedAction.appendToAction(resetAction)
		}
	}
	
	private def void customizeDeclarationNames(XSTS xSts, ComponentInstance instance) {
		val type = instance.derivedType
		if (type instanceof StatechartDefinition) {
			// Customizing every variable name
			for (variable : xSts.variableDeclarations) {
				variable.name = variable.getCustomizedName(instance)
			}
			// Customizing region type declaration name
			for (regionType : xSts.variableGroups.filter[it.annotation instanceof RegionGroup]
					.map[it.variables].flatten.map[it.type].filter(TypeReference).map[it.reference]) {
				regionType.name = regionType.customizeRegionTypeName(type)
			}
		}
	}
	
}