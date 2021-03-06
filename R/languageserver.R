#' @useDynLib languageserver
#' @details
#' An implementation of the Language Server Protocol for R
"_PACKAGE"


LanguageServer <- R6::R6Class("LanguageServer",
    public = list(
        tcp = FALSE,
        inputcon = NULL,
        outputcon = NULL,
        will_exit = NULL,
        request_handlers = NULL,
        notification_handlers = NULL,
        documents = new.env(),
        workspace = NULL,

        processId = NULL,
        rootUri = NULL,
        rootPath = NULL,
        initializationOptions = NULL,
        capabilities = NULL,

        sync_input_queue = NULL,
        sync_output_queue = NULL,
        reply_queue = NULL,

        initialize = function(host, port) {
            if (is.null(port)) {
                logger$info("connection type: stdio")
                outputcon <- stdout()
                inputcon <- file("stdin")
                # note: windows doesn't non-blocking read stdin
                open(inputcon, blocking = FALSE)
            } else {
                self$tcp <- TRUE
                logger$info("connection type: tcp at ", port)
                inputcon <- socketConnection(host = host, port = port, open = "r+")
                logger$info("connected")
                outputcon <- inputcon
            }

            self$inputcon <- inputcon
            self$outputcon <- outputcon
            self$register_handlers()

            self$workspace <- Workspace$new()
            self$sync_input_queue <- NamedQueue$new()
            self$sync_output_queue <- NamedQueue$new()
            self$reply_queue <- Queue$new()

            self$process_sync_input_queue <- leisurize(
                function() process_sync_input_queue(self), 0.3)
            self$process_sync_output_queue <- (function() process_sync_output_queue(self))
        },

        finalize = function() {
            close(self$inputcon)
        },

        deliver = function(message) {
            if (!is.null(message)) {
                cat(message$format(), file = self$outputcon)
            }
        },

        handle_raw = function(data) {
            tryCatch({
                payload <- jsonlite::fromJSON(data)
                pl_names <- names(payload)
                logger$info("received payload.")
            },
            error = function(e){
                logger$error("error handling json: ", e)
            })
            if ("id" %in% pl_names && "method" %in% pl_names) {
                self$handle_request(payload)
            } else if ("method" %in% pl_names) {
                self$handle_notification(payload)
            } else {
                logger$error("not request or notification")
            }
        },

        handle_request = function(request) {
            id <- request$id
            method <- request$method
            params <- request$params
            if (method %in% names(self$request_handlers)) {
                logger$info("handling request: ", method)
                tryCatch({
                    dispatch <- self$request_handlers[[method]]
                    dispatch(self, id, params)
                },
                error = function(e) {
                    logger$error("internal error: ", e)
                    self$deliver(ResponseErrorMessage$new(id, "InternalError", to_string(e)))
                })
            } else {
                logger$error("unknown request: ", method)
                self$deliver(ResponseErrorMessage$new(
                    id, "MethodNotFound", paste0("unknown request ", method)))
            }
        },

        handle_notification = function(notification) {
            method <- notification$method
            params <- notification$params
            if (method %in% names(self$notification_handlers)) {
                logger$info("handling notification: ", method)
                tryCatch({
                    dispatch <- self$notification_handlers[[method]]
                    dispatch(self, params)
                },
                error = function(e) {
                    logger$error("internal error: ", e)
                })
            } else {
                logger$error("unknown notification: ", method)
            }
        },

        register_handlers = function() {
            self$request_handlers <- list(
                initialize = on_initialize,
                shutdown = on_shutdown,
                `textDocument/completion` =  text_document_completion,
                `textDocument/hover` = text_document_hover,
                `textDocument/signatureHelp` = text_document_signature_help
            )

            self$notification_handlers <- list(
                initialized = on_initialized,
                exit = on_exit,
                `textDocument/didOpen` = text_document_did_open,
                `textDocument/didChange` = text_document_did_change,
                `textDocument/didSave` = text_document_did_save,
                `textDocument/didClose` = text_document_did_close
            )
        },

        process_events = function() {
            self$process_sync_input_queue()
            self$process_sync_output_queue()
            self$process_reply_queue()
        },

        process_sync_input_queue = NULL,

        process_sync_output_queue = NULL,

        process_reply_queue = function() {
            while (TRUE) {
                notification <- self$reply_queue$get()
                if (is.null(notification)) break
                self$deliver(notification)
            }
        },

        eventloop = function() {
            tcp <- self$tcp
            con <- self$inputcon
            while (TRUE) {
                ret <- try({
                    if (!isOpen(con)) {
                        self$will_exit <- TRUE
                    }

                    if (.Platform$OS.type == "unix" && getppid() == 1) {
                        # exit if the current process becomes orphan
                        self$will_exit <- TRUE
                    }

                    if (isTRUE(self$will_exit)) {
                        logger$info("exiting")
                        break
                    }

                    self$process_events()

                    if (tcp) {
                        if (!socketSelect(list(con), timeout = 0)) {
                            Sys.sleep(0.1)
                            next
                        }
                    }
                    header <- read_line(con)
                    if (length(header) == 0 || nchar(header) == 0) {
                        Sys.sleep(0.1)
                        next
                    }
                    logger$info("received: ", header)

                    matches <- stringr::str_match(header, "Content-Length: ([0-9]+)")
                    if (is.na(matches[2]))
                        stop("Unexpected input: ", header)

                    empty_line <- read_line(con)
                    while (length(empty_line) == 0) {
                        empty_line <- read_line(con)
                        Sys.sleep(0.05)
                    }
                    if (nchar(empty_line) > 0)
                        stop("Unexpected non-empty line")
                    nbytes <- as.integer(matches[2])
                    data <- ""
                    while (nbytes > 0) {
                        newdata <- read_char(con, nbytes)
                        if (length(newdata) > 0) {
                            nbytes <- nbytes - nchar(newdata, type = "bytes")
                            data <- paste0(data, newdata)
                        }
                        Sys.sleep(0.05)
                    }
                    self$handle_raw(data)
                })
                if (inherits(ret, "try-error")) {
                    logger$error(ret)
                    logger$error(as.list(traceback()))
                    logger$error("exiting")
                    break
                }
            }
        },

        run = function() {
            self$eventloop()
        }
    )
)


#' Run the R language server
#' @param debug set \code{TRUE} to show debug information in stderr
#' @param host the hostname used to create the tcp server, not used when \code{port} is \code{NULL}
#' @param port the port used to create the tcp server. If \code{NULL}, use stdio instead.
#' @examples
#' \dontrun{
#' # to use stdio
#' languageserver::run()
#'
#' # to use tcp server
#' languageserver::run(port = 8888)
#' }
#' @export
run <- function(debug = FALSE, host = "localhost", port = NULL) {
    tools::Rd2txt_options(underline_titles = FALSE)
    logger$set_mode(debug = debug)
    langserver <- LanguageServer$new(host, port)
    langserver$run()
}
