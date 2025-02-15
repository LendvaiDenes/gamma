/********************************************************************************
 * Copyright (c) 2018-2022 Contributors to the Gamma project
 *
 * All rights reserved. This program and the accompanying materials
 * are made available under the terms of the Eclipse Public License v1.0
 * which accompanies this distribution, and is available at
 * http://www.eclipse.org/legal/epl-v10.html
 *
 * SPDX-License-Identifier: EPL-1.0
 ********************************************************************************/
package hu.bme.mit.gamma.trace.language.scoping

import hu.bme.mit.gamma.expression.model.VariableDeclaration
import hu.bme.mit.gamma.statechart.composite.AsynchronousCompositeComponent
import hu.bme.mit.gamma.statechart.composite.ComponentInstanceVariableReferenceExpression
import hu.bme.mit.gamma.statechart.composite.CompositeModelPackage
import hu.bme.mit.gamma.statechart.statechart.Region
import hu.bme.mit.gamma.statechart.statechart.State
import hu.bme.mit.gamma.statechart.statechart.StatechartModelPackage
import hu.bme.mit.gamma.trace.model.ExecutionTrace
import hu.bme.mit.gamma.trace.model.InstanceSchedule
import hu.bme.mit.gamma.trace.model.InstanceStateConfiguration
import hu.bme.mit.gamma.trace.model.RaiseEventAct
import hu.bme.mit.gamma.trace.model.TraceModelPackage
import hu.bme.mit.gamma.trace.util.TraceUtil
import java.util.HashSet
import org.eclipse.emf.ecore.EObject
import org.eclipse.emf.ecore.EReference
import org.eclipse.xtext.scoping.IScope
import org.eclipse.xtext.scoping.Scopes

import static extension hu.bme.mit.gamma.statechart.derivedfeatures.StatechartModelDerivedFeatures.*

class TraceLanguageScopeProvider extends AbstractTraceLanguageScopeProvider {

	new() {
		super.util = TraceUtil.INSTANCE
	}

	override getScope(EObject context, EReference reference) {
		if (context instanceof ExecutionTrace && reference == TraceModelPackage.Literals.EXECUTION_TRACE__COMPONENT) {
			val executionTrace = context as ExecutionTrace
			if (executionTrace.import !== null) {
				return Scopes.scopeFor(executionTrace.import.components)
			}
		}
		if (context instanceof RaiseEventAct && reference == StatechartModelPackage.Literals.RAISE_EVENT_ACTION__PORT) {
			val executionTrace = ecoreUtil.getContainerOfType(context, ExecutionTrace)
			val component = executionTrace.component
			return Scopes.scopeFor(component.allPorts)
		}
		if (context instanceof RaiseEventAct && reference == StatechartModelPackage.Literals.RAISE_EVENT_ACTION__EVENT) {
			val raiseEventAct = context as RaiseEventAct
			if (raiseEventAct.port !== null) {
				val port = raiseEventAct.port
				try {
					val events = port.allEvents
					return Scopes.scopeFor(events)
				} catch (NullPointerException e) {
					// For some reason dirty editor errors emerge
					return super.getScope(context, reference)
				}
			}
		}	
		if (context instanceof InstanceSchedule &&
				reference == TraceModelPackage.Literals.INSTANCE_SCHEDULE__SCHEDULED_INSTANCE) {
			val executionTrace = ecoreUtil.getContainerOfType(context, ExecutionTrace)
			val component = executionTrace.component
			if (component instanceof AsynchronousCompositeComponent) {
				val instances = component.allAsynchronousSimpleInstances
				return Scopes.scopeFor(instances)
			}
		}
		if (reference == CompositeModelPackage.Literals.COMPONENT_INSTANCE_REFERENCE_EXPRESSION__COMPONENT_INSTANCE) {
			val executionTrace = ecoreUtil.getContainerOfType(context, ExecutionTrace)
			val component = executionTrace.component
			val instances = component.allInstances // Both atomic and chain references are supported
			return Scopes.scopeFor(instances)
		}
		if (context instanceof InstanceStateConfiguration) {
			val instance = context.instance
			val instanceType = instance.lastInstance.derivedType
			val executionTrace = ecoreUtil.getContainerOfType(context, ExecutionTrace)
			val component = executionTrace.component
			if (reference == CompositeModelPackage.Literals.COMPONENT_INSTANCE_STATE_REFERENCE_EXPRESSION__REGION) {
				val regions = new HashSet<Region>
				if (instanceType === null) {
					val simpleSyncInstances = component.allSimpleInstances
					for (simpleInstance : simpleSyncInstances) {
						regions += ecoreUtil.getAllContentsOfType(simpleInstance.type, Region)
					}
				}
				else {
					regions += ecoreUtil.getAllContentsOfType(instanceType, Region)
				}
				return Scopes.scopeFor(regions)
			}
			if (reference == CompositeModelPackage.Literals.COMPONENT_INSTANCE_STATE_REFERENCE_EXPRESSION__STATE) {
				val region = context.region
				if (region !== null) {
					return Scopes.scopeFor(region.states) 
				}
				else {
					val states = new HashSet<State>
					if (instanceType === null) {
						val simpleSyncInstances = component.allSimpleInstances
						for (simpleInstance : simpleSyncInstances) {
							states += ecoreUtil.getAllContentsOfType(simpleInstance.type, State)
						}
					}
					else {
						states += ecoreUtil.getAllContentsOfType(instanceType, State)
					}
					return Scopes.scopeFor(states)
				}
			}
		}
		if (reference == CompositeModelPackage.Literals
				.COMPONENT_INSTANCE_VARIABLE_REFERENCE_EXPRESSION__VARIABLE_DECLARATION) {
			val instanceVariableState = ecoreUtil.getSelfOrContainerOfType(
					context, ComponentInstanceVariableReferenceExpression)
			val instance = instanceVariableState.instance
			val instanceType = instance.lastInstance.derivedType
			if (instanceType === null) {
				return IScope.NULLSCOPE
			}
			val variables = ecoreUtil.getAllContentsOfType(instanceType, VariableDeclaration)
			return Scopes.scopeFor(variables)
		}
		super.getScope(context, reference)
	}

}