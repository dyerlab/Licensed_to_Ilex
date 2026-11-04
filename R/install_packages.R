# install_packages.R
# Finds every R package used by this project's .R, .qmd, and .Rmd files and
# installs any that are missing. Uses base R only, so it runs on a fresh machine.
#
#   Rscript R/install_packages.R             # install what is missing
#   Rscript R/install_packages.R --dry-run   # only report

# Not referenced in the code, but Quarto needs them to render R documents.
implied <- c("knitr", "rmarkdown")

file_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
root <- if (length(file_arg)) {
  dirname(dirname(normalizePath(sub("^--file=", "", file_arg))))
} else {
  getwd()
}

# Tracked and untracked-but-not-ignored files, which skips data/ and docs output.
files <- system2("git", c("-C", shQuote(root), "ls-files", "--cached", "--others",
                          "--exclude-standard", "'*.R'", "'*.qmd'", "'*.Rmd'"),
                 stdout = TRUE)
files <- file.path(root, files[file.exists(file.path(root, files))])

# Returns the code in a file; for documents, only the contents of {r} chunks.
read_code <- function(path) {
  lines <- readLines(path, warn = FALSE)
  if (grepl("\\.R$", path)) return(lines)
  fences <- grepl("^\\s*```", lines)
  in_block <- cumsum(fences) %% 2 == 1 & !fences
  block_id <- cumsum(fences)
  r_blocks <- block_id[fences & grepl("^\\s*```+\\{r\\b", lines)]
  lines[in_block & block_id %in% r_blocks]
}

# Returns package names from pkg::fn, pkg:::fn, and library()-style calls.
packages_in <- function(path) {
  parsed <- tryCatch(parse(text = read_code(path), keep.source = TRUE),
                     error = function(e) {
                       message("Skipping (could not parse): ", path)
                       NULL
                     })
  if (is.null(parsed) || length(parsed) == 0) return(character())
  tokens <- getParseData(parsed)
  tokens <- tokens[tokens$terminal, ]
  loaders <- which(tokens$token == "SYMBOL_FUNCTION_CALL" &
                     tokens$text %in% c("library", "require", "requireNamespace",
                                        "loadNamespace"))
  args <- tokens$text[pmin(loaders + 2, nrow(tokens))]
  c(tokens$text[tokens$token == "SYMBOL_PACKAGE"], gsub("[\"']", "", args))
}

used <- sort(unique(c(implied, unlist(lapply(files, packages_in)))))
missing <- used[!vapply(used, function(p) nzchar(system.file(package = p)), logical(1))]

cat(sprintf("Scanned %d files: %d packages used, %d missing.\n",
            length(files), length(used), length(missing)))
cat("Used:   ", paste(used, collapse = ", "), "\n")
cat("Missing:", if (length(missing)) paste(missing, collapse = ", ") else "none", "\n")

if (length(missing) && !"--dry-run" %in% commandArgs(TRUE)) {
  if (identical(unname(getOption("repos")["CRAN"]), "@CRAN@")) {
    options(repos = c(CRAN = "https://cran.r-project.org"))
  }
  # Prefer prebuilt binaries: compiling sf and terra from source is slow and fragile.
  options(install.packages.compile.from.source = "never")
  install.packages(missing)

  # install.packages() only warns on failure, so check the result explicitly.
  failed <- missing[!vapply(missing, function(p) nzchar(system.file(package = p)), logical(1))]
  if (length(failed)) {
    message("Failed to install: ", paste(failed, collapse = ", "))
    quit(status = 1)
  }
  cat("Installed:", paste(missing, collapse = ", "), "\n")
}
