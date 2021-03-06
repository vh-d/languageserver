signature_reply <- function(id, workspace, document, position) {
    line <- position$line
    character <- position$character

    closure <- detect_closure(document, line, character)

    SignatureInformation <- list()
    activeSignature <- -1


    if (!is.null(closure$funct)) {
        if (is.null(closure$package)) {
            sig <- workspace$get_signature(closure$funct)
        } else {
            sig <- workspace$get_signature(closure$funct, closure$package)
        }

        logger$info("sig:", workspace$get_signature("file.path"))
        if (!is.null(sig)) {
            sig <- trimws(gsub("function ", closure$funct, sig))
            SignatureInformation <- list(list(label = sig))
            activeSignature <- 0
        }
    }

    Response$new(
        id,
        result = list(
            signatures = SignatureInformation,
            activeSignature = activeSignature
        )
    )
}
