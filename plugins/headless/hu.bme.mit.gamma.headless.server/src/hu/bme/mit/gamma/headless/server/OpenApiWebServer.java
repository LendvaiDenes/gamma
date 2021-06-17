package hu.bme.mit.gamma.headless.server;

import io.vertx.core.AbstractVerticle;
import io.vertx.core.Future;
import io.vertx.core.Handler;
import io.vertx.core.Promise;
import io.vertx.core.Vertx;
import io.vertx.core.http.HttpHeaders;
import io.vertx.core.http.HttpMethod;
import io.vertx.core.http.HttpServer;
import io.vertx.core.http.HttpServerOptions;
import io.vertx.core.json.Json;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.FileUpload;
import io.vertx.ext.web.Route;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;
import io.vertx.ext.web.handler.SessionHandler;
import io.vertx.ext.web.openapi.RouterBuilder;
import io.vertx.ext.web.openapi.RouterBuilderOptions;
import io.vertx.ext.web.sstore.LocalSessionStore;
import io.vertx.ext.web.validation.RequestParameters;
import hu.bme.mit.gamma.headless.server.service.Provider;
import hu.bme.mit.gamma.headless.server.service.Validator;
import hu.bme.mit.gamma.headless.server.entity.WorkspaceProjectWrapper;
import hu.bme.mit.gamma.headless.server.service.ProcessBuilderCli;
import hu.bme.mit.gamma.headless.server.util.FileHandlerUtil;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.lang.reflect.Field;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.logging.Level;
import java.util.logging.Logger;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

import org.apache.commons.lang3.StringUtils;

public class OpenApiWebServer extends AbstractVerticle {
	private static final String APPLICATION_JSON = "application/json";
	private static final String MESSAGE = "message";
	private static final String WORKSPACE = "workspace";
	private static final String PARSED_PARAMETERS = "parsedParameters";
	private static final String PROJECT_NAME = "project";
	HttpServer server;
	private static final String DIRECTORY_OF_WORKSPACES_PROPERTY_NAME = "root.of.workspaces.path";

	private static final String ANSI_RESET = "\u001B[0m";
	private static final String ANSI_GREEN = "\u001B[32m";
	private static final String ANSI_RED = "\u001B[31m";
	private static final String ANSI_YELLOW = "\u001B[33m";

	protected static Logger logger = Logger.getLogger("GammaLogger");

	@Override
	public void start(Promise<Void> future) {
		RouterBuilder.create(this.vertx, "gamma-wrapper.yaml", ar -> {
			SessionHandler sessionHandler = SessionHandler.create(LocalSessionStore.create(vertx));

			RouterBuilder routerFactory;
			if (ar.succeeded()) {
				routerFactory = ar.result();
				routerFactory.createRouter().route().handler(sessionHandler);
				routerFactory.operation("runOperation").handler(routingContext -> {

					logger.log(Level.INFO, ANSI_YELLOW + "Operation \"runOperation\" has started." + ANSI_RESET);

					ErrorHandlerPOJO errorHandlerPOJO = null;
					RequestParameters params = routingContext.get(PARSED_PARAMETERS);
					String projectName = params.pathParameter(PROJECT_NAME).getString();
					String workspace = params.pathParameter(WORKSPACE).getString();
					String filePath = routingContext.request().formAttributes().get("ggenPath");
					boolean success = false;
					try {
						errorHandlerPOJO = getErrorObject(workspace, projectName);
						if (errorHandlerPOJO.getErrorObject() == null) {
							success = true;
							ProcessBuilderCli.runGammaOperations(projectName, workspace, filePath);
							logger.log(Level.INFO,
									ANSI_YELLOW + "Operation \"runOperation\": parameters passed to CLI." + ANSI_RESET);
						}
					} catch (IOException e) {
						e.printStackTrace();
					}
					if (success) {
						routingContext.response().setStatusCode(200)
								.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON).end();
					} else {
						sendErrorResponse(routingContext, errorHandlerPOJO);
					}
				});

				routerFactory.operation("getResult").handler(routingContext -> {

					logger.log(Level.INFO, ANSI_YELLOW + "Operation \"getResult\" has started." + ANSI_RESET);

					ErrorHandlerPOJO errorHandlerPOJO = null;
					String zipPath = null;
					RequestParameters params = routingContext.get(PARSED_PARAMETERS);
					String projectName = params.pathParameter(PROJECT_NAME).getString();
					String workspace = params.pathParameter(WORKSPACE).getString();
					JsonObject json = routingContext.getBodyAsJson();
					JsonArray jsonArray = json.getJsonArray("resultDirs");

					boolean success = false;
					try {
						errorHandlerPOJO = getErrorObject(workspace, projectName);
						if (errorHandlerPOJO.getErrorObject() == null) {
							success = true;
							zipPath = Provider.getResultZipFilePath(jsonArray, FileHandlerUtil
									.getProperty(DIRECTORY_OF_WORKSPACES_PROPERTY_NAME).concat(workspace), projectName);
							logger.log(Level.INFO,
									ANSI_YELLOW + "Operation \"getResult\": results zipped successfully." + ANSI_RESET);
						}
					} catch (IOException e) {
						e.printStackTrace();
					}
					if (success && zipPath != null) {
						routingContext.response().setStatusCode(200)
								.putHeader(HttpHeaders.CONTENT_TYPE, "application/zip").sendFile(zipPath);
					} else {
						sendErrorResponse(routingContext, errorHandlerPOJO);
					}
				});

				routerFactory.operation("getLogs").handler(routingContext -> {
					RequestParameters params = routingContext.get(PARSED_PARAMETERS);
					String workspace = params.pathParameter(WORKSPACE).getString();
					String logPath = FileHandlerUtil.getProperty(DIRECTORY_OF_WORKSPACES_PROPERTY_NAME) + File.separator
							+ workspace + File.separator + ".metadata" + File.separator + ".log";
					boolean success = false;
					try {
						FileInputStream inputLog = new FileInputStream(logPath);
						inputLog.close();
						success = true;
					} catch (FileNotFoundException e) {
						// TODO Auto-generated catch block
						e.printStackTrace();
					} catch (IOException e) {
						// TODO Auto-generated catch block
						e.printStackTrace();
					}

					if (success) {
						routingContext.response().setStatusCode(200).putHeader(HttpHeaders.CONTENT_TYPE, "text/plain")
								.sendFile(logPath);
					} else {
						JsonObject errorObject = new JsonObject().put("code", 404).put(MESSAGE,
								"The log file requested does not exist.");
						routingContext.response().setStatusCode(404)
								.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON).end(errorObject.encode());
					}

				});

				routerFactory.operation("addProject").handler(routingContext -> {

					logger.log(Level.INFO, ANSI_YELLOW + "Operation \"addProject\" has started." + ANSI_RESET);

					RequestParameters params = routingContext.get(PARSED_PARAMETERS);
					String workspace = params.pathParameter(WORKSPACE).getString();
					boolean success = true;
					for (FileUpload f : routingContext.fileUploads()) {
						try {
							if (!Validator.checkIfWorkspaceExists(workspace) || f.size() == 0
									|| Validator.checkIfProjectAlreadyExistsUnderWorkspace(workspace,
											f.fileName().substring(0, f.fileName().lastIndexOf(".")))) {
								success = false;
							} else {
								Files.move(Paths.get(f.uploadedFileName()),
										Paths.get(FileHandlerUtil.getProperty(DIRECTORY_OF_WORKSPACES_PROPERTY_NAME)
												+ workspace + File.separator + f.fileName()));
								String projectName = f.fileName().substring(0, f.fileName().lastIndexOf("."));
								ProcessBuilderCli.createEclipseProject(projectName, workspace);
								logger.log(Level.INFO, ANSI_YELLOW
										+ "Operation \"addProject\": parameters passed to CLI." + ANSI_RESET);
							}
						} catch (IOException | InterruptedException e) {
							e.printStackTrace();
						}
					}
					if (success) {
						routingContext.response().end();
					} else {
						JsonObject errorObject = new JsonObject().put("code", 400).put(MESSAGE,
								"Project already exists under this workspace, delete it and resend this request or did not provide a valid workspace");
						routingContext.response().setStatusCode(400)
								.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON).end(errorObject.encode());
					}
				});

				routerFactory.operation("addWorkspace").handler(routingContext -> {

					logger.log(Level.INFO, ANSI_YELLOW + "Operation \"addWorkspace\" has started." + ANSI_RESET);

					String workspaceUUID = "";
					try {
						workspaceUUID = ProcessBuilderCli.createWorkspaceForUser();
						logger.log(Level.INFO,
								ANSI_YELLOW + "Operation \"addWorkspace\": parameters passed to CLI." + ANSI_RESET);
					} catch (IOException | InterruptedException e) {
						e.printStackTrace();
					}
					if (StringUtils.isEmpty(workspaceUUID)) {
						routingContext.response().setStatusCode(500).end();
					} else {
						routingContext.response().setStatusCode(200)
								.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON).end(Json.encode(workspaceUUID));
					}
				});

				routerFactory.operation("stopOperation").handler(routingContext -> {

					logger.log(Level.INFO, ANSI_YELLOW + "Operation \"stopOperation\" has started." + ANSI_RESET);

					ErrorHandlerPOJO errorHandlerPOJO = null;
					RequestParameters params = routingContext.get(PARSED_PARAMETERS);
					String workspace = params.pathParameter(WORKSPACE).getString();
					String projectName = params.pathParameter(PROJECT_NAME).getString();
					boolean success = false;
					try {
						errorHandlerPOJO = getErrorObject(workspace, projectName);
						if (errorHandlerPOJO.getStatusCode() == 503) {
							ProcessBuilderCli.stopOperation(projectName, workspace);
							logger.log(Level.INFO, ANSI_YELLOW
									+ "Operation \"stopOperation\": parameters passed to CLI." + ANSI_RESET);
							success = true;
						}
					} catch (IOException e) {
						e.printStackTrace();
					}
					if (success) {
						routingContext.response().setStatusCode(200)
								.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON).end();
					} else {
						sendErrorResponse(routingContext, errorHandlerPOJO);
					}
				});

				routerFactory.operation("deleteProject").handler(routingContext -> {

					logger.log(Level.INFO, ANSI_YELLOW + "Operation \"deleteProject\" has started." + ANSI_RESET);

					ErrorHandlerPOJO errorHandlerPOJO = null;
					RequestParameters params = routingContext.get(PARSED_PARAMETERS);
					String projectName = params.pathParameter(PROJECT_NAME).getString();
					String workspace = params.pathParameter(WORKSPACE).getString();

					boolean success = false;
					try {
						errorHandlerPOJO = getErrorObject(workspace, projectName);
						if (errorHandlerPOJO.getErrorObject() == null) {
							success = true;
							Provider.deleteProject(workspace, projectName);
						}
					} catch (IOException e) {
						e.printStackTrace();
					}
					if (success) {
						routingContext.response().setStatusCode(200)
								.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON).end();
					} else {
						sendErrorResponse(routingContext, errorHandlerPOJO);
					}
				});
				
				routerFactory.operation("deleteWorkspace").handler(routingContext -> {
					
					logger.log(Level.INFO, ANSI_YELLOW + "Operation \"deleteWorkspace\" has started." + ANSI_RESET);
					
					ErrorHandlerPOJO errorHandlerPOJO = null;
					RequestParameters params = routingContext.get(PARSED_PARAMETERS);
					String workspace = params.pathParameter(WORKSPACE).getString();
					
					boolean success = Provider.deleteWorkspace(workspace);
					
					if (success) {
						routingContext.response().setStatusCode(200)
						.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON).end();
					} else {
						JsonObject errorObject = new JsonObject().put("code", 400).put(MESSAGE,
								"Workspace can't be deleted. Make sure that the workspace exists, and that it is empty.");
						routingContext.response().setStatusCode(400)
								.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON).end(errorObject.encode());
					}
				});

				routerFactory.operation("getStatus").handler(routingContext -> {

					logger.log(Level.INFO, ANSI_YELLOW + "Operation \"getStatus\" has started." + ANSI_RESET);

					ErrorHandlerPOJO errorHandlerPOJO = null;
					RequestParameters params = routingContext.get(PARSED_PARAMETERS);
					String projectName = params.pathParameter(PROJECT_NAME).getString();
					String workspace = params.pathParameter(WORKSPACE).getString();
					JsonObject returnedResult = null;
					boolean success = false;
					try {
						errorHandlerPOJO = getErrorObject(workspace, projectName);
						if (errorHandlerPOJO.getErrorObject() == null) {
							success = true;
							if (Validator.checkIfProjectIsUnderLoad(workspace, projectName)) {
								returnedResult = new JsonObject().put("code", 503).put(MESSAGE, "Project " + projectName
										+ " in workspace " + workspace
										+ " is currently under operation. Wait for the operation to finish to start a new one.");
							} else {
								returnedResult = new JsonObject().put("code", 200).put(MESSAGE, "Project " + projectName
										+ " in workspace " + workspace + " is currently idle.");
							}
						}
					} catch (IOException e) {
						e.printStackTrace();
					}

					if (success) {
						routingContext.response().setStatusCode(200)
								.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON).end(Json.encode(returnedResult));
					} else {
						sendErrorResponse(routingContext, errorHandlerPOJO);
					}
				});

				routerFactory.operation("addAndRun").handler(routingContext -> {

					logger.log(Level.INFO, ANSI_YELLOW + "Operation \"addAndRun\" has started." + ANSI_RESET);

					ErrorHandlerPOJO errorHandlerPOJO = null;
					RequestParameters params = routingContext.get(PARSED_PARAMETERS);
					String ggenPath = routingContext.request().formAttributes().get("ggenPath");
					String workspace = params.pathParameter(WORKSPACE).getString();
					String fileName = "";
					boolean successUpload = true;
					boolean successGgen = false;
					for (FileUpload f : routingContext.fileUploads()) {
						fileName = f.fileName().replace(".zip", "");
						try {
							if (!Validator.checkIfWorkspaceExists(workspace) || f.size() == 0
									|| Validator.checkIfProjectAlreadyExistsUnderWorkspace(workspace,
											f.fileName().substring(0, f.fileName().lastIndexOf(".")))) {
								successUpload = false;
							} else {
								Files.move(Paths.get(f.uploadedFileName()),
										Paths.get(FileHandlerUtil.getProperty(DIRECTORY_OF_WORKSPACES_PROPERTY_NAME)
												+ workspace + File.separator + f.fileName()));
								String projectName = f.fileName().substring(0, f.fileName().lastIndexOf("."));
								ProcessBuilderCli.createEclipseProject(projectName, workspace);

								logger.log(Level.INFO, ANSI_YELLOW
										+ "Operation \"addAndRun\": parameters passed to CLI, importing project. "
										+ ANSI_RESET);
							}
						} catch (IOException | InterruptedException e) {
							e.printStackTrace();
						}
					}

					try {
						errorHandlerPOJO = getErrorObject(workspace, fileName);
						if (errorHandlerPOJO.getErrorObject() == null) {
							successGgen = true;
							ProcessBuilderCli.runGammaOperations(fileName, workspace,
									ggenPath.replace("/", File.separator));
							logger.log(Level.INFO, ANSI_YELLOW
									+ "Operation \"addAndRund\": parameters passed to CLI, running ggen." + ANSI_RESET);
						}
					} catch (IOException e) {
						e.printStackTrace();
					}

					if (successGgen && successUpload) {
						routingContext.response().setStatusCode(200)
								.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON).end();
					} else {
						JsonObject errorObject = new JsonObject().put("code", 400).put(MESSAGE,
								"Project already exists under this workspace, delete it and resend this request or did not provide a valid workspace");
						routingContext.response().setStatusCode(400)
								.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON).end(errorObject.encode());
					}
				});

				routerFactory.operation("list").handler(routingContext -> {

					logger.log(Level.INFO, ANSI_YELLOW + "Operation \"list\" has started." + ANSI_RESET);

					ErrorHandlerPOJO errorHandlerPOJO = null;
					RequestParameters params = routingContext.get(PARSED_PARAMETERS);
					String projectName = params.pathParameter(PROJECT_NAME).getString();
					String workspace = params.pathParameter(WORKSPACE).getString();
					List<String> result = new ArrayList<String>();
					String returnedResult = "";
					boolean success = false;
					try {
						errorHandlerPOJO = getErrorObject(workspace, projectName);
						if (errorHandlerPOJO.getErrorObject() == null) {
							success = true;
							try (Stream<Path> walk = Files
									.walk(Paths.get(FileHandlerUtil.getProperty(DIRECTORY_OF_WORKSPACES_PROPERTY_NAME)
											+ workspace + File.separator + projectName))) {
								// We want to find only regular files
								result = walk.filter(Files::isRegularFile).map(x -> x.toString())
										.collect(Collectors.toList());
								for (int i = 0; i < result.size(); i++) {
									returnedResult = returnedResult + result.get(i) + "\n";
								}
							} catch (IOException e) {
								success = false;
								e.printStackTrace();
							}
						}
					} catch (IOException e) {
						e.printStackTrace();
					}

					if (success) {
						routingContext.response().setStatusCode(200)
								.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON).end(returnedResult);
					} else {
						sendErrorResponse(routingContext, errorHandlerPOJO);
					}
				});

				routerFactory.operation("setLogLevel").handler(routingContext -> {

					logger.log(Level.INFO, ANSI_YELLOW + "Operation \"setLogLevel\" has started." + ANSI_RESET);

					RequestParameters params = routingContext.get(PARSED_PARAMETERS);
					String logLevel = params.pathParameter("logLevel").getString().toLowerCase();
					boolean success = false;

					switch (logLevel) {
					case "info":
						logger.setLevel(Level.INFO);
						ProcessBuilderCli.setProcessCliLogLevel(Level.INFO);
						success = true;
						break;
					case "warning":
						logger.setLevel(Level.WARNING);
						ProcessBuilderCli.setProcessCliLogLevel(Level.WARNING);
						success = true;
						break;
					case "severe":
						logger.setLevel(Level.SEVERE);
						ProcessBuilderCli.setProcessCliLogLevel(Level.SEVERE);
						success = true;
						break;
					case "off":
						logger.setLevel(Level.OFF);
						ProcessBuilderCli.setProcessCliLogLevel(Level.OFF);
						success = true;
						break;
					}

					if (success) {
						routingContext.response().setStatusCode(200)
								.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON)
								.end("Logger level successfully set to: " + logLevel);
					} else {
						JsonObject errorObject = new JsonObject().put("code", 400).put(MESSAGE,
								"The provided log level was incorrect. The following levels are accepted: \"info\", \"warning\", \"severe\" and \"off\". ");
						routingContext.response().setStatusCode(400)
								.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON).end(errorObject.encode());
					}
				});

				Router router = routerFactory.createRouter();

				router.errorHandler(404, routingContext -> {
					JsonObject errorObject = new JsonObject().put("code", 404).put(MESSAGE,
							(routingContext.failure() != null) ? routingContext.failure().getMessage() : "Not Found");
					routingContext.response().setStatusCode(404).putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON)
							.end(errorObject.encode());
				});

				server = vertx.createHttpServer(new HttpServerOptions().setPort(8080).setHost("localhost")); // <5>
				server.requestHandler(x -> {
					router.handle(x);
				}).listen(8080);

				future.complete();
			} else {
				future.fail(ar.cause());
			}
		});
	}

	private ErrorHandlerPOJO getErrorObject(String workspace, String projectName) throws IOException {
		ErrorHandlerPOJO errorHandlerPOJO = new ErrorHandlerPOJO(null, 0);
		JsonObject errorObject;
		if (!Validator.checkIfProjectAlreadyExistsUnderWorkspace(workspace, projectName)) {
			errorObject = new JsonObject().put("code", 404).put(MESSAGE,
					"Project " + projectName + " does not exists under this workspace!");
			errorHandlerPOJO.setStatusCode(404);
			errorHandlerPOJO.setErrorObject(errorObject);
		} else if (Validator.checkIfProjectIsUnderLoad(workspace, projectName)) {
			errorObject = new JsonObject().put("code", 503).put(MESSAGE,
					"There is an in progress operation on this project, try again later!");
			errorHandlerPOJO.setStatusCode(503);
			errorHandlerPOJO.setErrorObject(errorObject);
		}
		return errorHandlerPOJO;
	}

	private void sendErrorResponse(RoutingContext routingContext, ErrorHandlerPOJO errorHandlerPOJO) {
		routingContext.response().setStatusCode(errorHandlerPOJO.getStatusCode())
				.putHeader(HttpHeaders.CONTENT_TYPE, APPLICATION_JSON).end(errorHandlerPOJO.getErrorObject().encode());
	}

	private static void listWorkspacesAndProjects() throws IOException {
		if (FileHandlerUtil.getWrapperListFromJson() != null) {
			List<WorkspaceProjectWrapper> yourList = FileHandlerUtil.getWrapperListFromJson();
			logger.log(Level.INFO, System.lineSeparator() + "Currently ongoing operations: ");
			boolean noOp = true;
			for (int i = 0; i < yourList.size(); i++) {
				if (yourList.get(i).getProjectName() != null) {
					if (Validator.checkIfProjectIsUnderLoad(yourList.get(i).getWorkspace(),
							yourList.get(i).getProjectName())) {
						if (noOp) {
							noOp = false;
						}
						logger.log(Level.INFO, '\t' + "Workspace: " + yourList.get(i).getWorkspace() + " Project: "
								+ yourList.get(i).getProjectName());
					}
				}
			}
			if (noOp) {
				logger.log(Level.INFO, '\t' + "none");
			}
			logger.log(Level.WARNING, "This is a WARNING level log");
			logger.log(Level.SEVERE, "This is a SEVERE level log");
		} else {
			logger.log(Level.INFO, "No workspaces are present.");
			logger.log(Level.WARNING, "This is a WARNING level log");
			logger.log(Level.SEVERE, "This is a SEVERE level log");
		}
	}

	@Override
	public void stop() {
		this.server.close();
	}

	public static void main(String[] args) {
		Vertx vertx = Vertx.vertx();
		vertx.setPeriodic(10000, aLong -> {
			try {
				listWorkspacesAndProjects();
			} catch (IOException e) {
				e.printStackTrace();
			}
		});
		vertx.deployVerticle(new OpenApiWebServer(), ar -> {
			if (ar.succeeded()) {
				// Logger rootLogger = Logger.getLogger("");
				// rootLogger.setLevel(Level.SEVERE);
//				logger.setLevel(Level.SEVERE);
				logger.log(Level.INFO, ANSI_GREEN + "Headless Gamma OpenAPI server is running." + ANSI_RESET);

			} else {
				logger.log(Level.INFO, ANSI_RED + "Headless Gamma OpenAPI server failed to start." + ANSI_RESET);
				logger.log(Level.INFO, System.getProperties().getProperty("user.dir"));
				Future.failedFuture(ar.cause());
			}
		});
	}

	public class ErrorHandlerPOJO {
		int statusCode;
		JsonObject errorObject;

		public ErrorHandlerPOJO(JsonObject errorObject, int statusCode) {
			this.errorObject = errorObject;
			this.statusCode = statusCode;
		}

		public JsonObject getErrorObject() {
			return errorObject;
		}

		public void setErrorObject(JsonObject errorObject) {
			this.errorObject = errorObject;
		}

		public int getStatusCode() {
			return statusCode;
		}

		public void setStatusCode(int statusCode) {
			this.statusCode = statusCode;
		}

	}

}
