#' Convert ICD data between formats and structures.
#'
#' ICD codes are represented in \emph{short} and \emph{decimal} forms. The
#' short form has up to 5 digits, or V or E followed by up to four digits. The
#' decimal form has a decimal point to delimit the top-level (henceforth
#' \emph{major}) category, and the \emph{minor} part containing the subsidiary
#' classifications.
#'
#' For conversions of ICD-9 or ICD-10 codes between the \emph{short} and
#' \emph{decimal} forms, use \code{\link{short_to_decimal}} and
#' \code{\link{decimal_to_short}}.
#'
#' \pkg{icd} does not covert ICD-9 to ICD-10 codes yet.
#'
#' @family ICD data conversion
#' @name convert
NULL

#' Convert chapters to lists of codes for use as a comorbidity map
#'
#' The chapter headings can be converted into the full set of their children,
#' and then used to look-up which chapter, sub-chapter, or 'major' a given code
#' belongs. Always returns a map with short-form ICD-9 codes. These can be
#' converted in bulk with \code{lapply} and \code{short_to_decimal}.
#' @param x Either a chapter list itself, or the name of one, e.g.
#'   \code{icd9_sub_chapters}
#' @param defined Single logical value, if \code{TRUE}, the default, only
#'   officially defined ICD-9 (currently ICD-9-CM) codes will be used in the
#'   expansion, not any syntactically possible ICD-9 code.
#' @keywords internal manip
#' @export
chapters_to_map <- function(x, defined = TRUE) {
  if (is.character(x) && exists(x)) x <- get(x)
  stopifnot(is.list(x))
  stopifnot(all(vapply(x, is.character, logical(1))))
  ranges <- names(x)
  map <- list()
  for (r in ranges) {
    map[[r]] <- expand_range(x[[r]][1],
      x[[r]][2],
      short_code = TRUE,
      defined = defined
    )
  }
  map
}

#' Convert ICD data from wide to long format
#' @template widevlong
#' @details Reshaping data is a common task, and is made easier here by knowing
#'   more about the underlying structure of the data. This function wraps the
#'   \code{\link[stats]{reshape}} function with specific behavior and checks
#'   related to ICD codes. Empty strings and NA values will be dropped, and
#'   everything else kept. No validation of the ICD codes is done.
#' @param x \code{data.frame} in wide format, i.e. one row per patient, and
#'   multiple columns containing ICD codes, empty strings or NA.
#' @template visit_name
#' @param icd_labels vector of column names in which codes are found. If NULL,
#'   all columns matching the regular expression \code{icd_regex} will be
#'   included.
#' @template icd_name
#' @param icd_regex vector of character strings containing a regular expression
#'   to identify ICD-9 diagnosis columns to try (case-insensitive) in order.
#'   Default is \code{c("icd", "diag", "dx_", "dx")}
#' @return \code{data.frame} with visit_name column named the same as input, and
#'   a column named by \code{icd.name} containing all the non-NA and non-empty
#'   codes found in the wide input data.
#' @examples
#' widedf <- data.frame(
#'   visit_name = c("a", "b", "c"),
#'   icd9_01 = c("441", "4424", "441"),
#'   icd9_02 = c(NA, "443", NA)
#' )
#' wide_to_long(widedf)
#' @family ICD data conversion
#' @export
wide_to_long <- function(x,
                         visit_name = get_visit_name(x),
                         icd_labels = NULL,
                         icd_name = "icd_code",
                         icd_regex = c("icd", "diag", "dx_", "dx")) {
  stopifnot(is.data.frame(x), nrow(x) > 0, ncol(x) >= 2)
  # explicitly make a data frame so tibble works (and maybe data.table, too?)
  x <- as.data.frame(x)
  assert_string(visit_name)
  stopifnot(is.null(icd_labels) || is.character(icd_labels))
  assert_string(icd_name)
  stopifnot(is.character(icd_regex), nchar(icd_regex) > 0)
  if (is.null(icd_labels)) {
    re <- length(icd_regex)
    while (re > 0) {
      icd_labels <- grep(rev(icd_regex)[re], names(x),
        ignore.case = TRUE, value = TRUE
      )
      if (length(icd_labels)) break
      re <- re - 1
    }
  }
  assert_character(icd_labels,
    any.missing = FALSE, min.chars = 1,
    min.len = 1, max.len = ncol(x) - 1
  )
  stopifnot(all(icd_labels %in% names(x)))
  res <- stats::reshape(x,
    direction = "long",
    varying = icd_labels,
    idvar = visit_name,
    timevar = NULL,
    v.names = icd_name
  )
  res <- res[!is.na(res[[icd_name]]), ]
  res <- res[nchar(as_char_no_warn(res[[icd_name]])) > 0, ]
  res <- res[order(res[[visit_name]]), ]
  rownames(res) <- NULL
  icd_long_data(res)
}

#' Convert ICD data from long to wide format
#' @template widevlong
#' @details This is more complicated than expected using \code{base::reshape} or
#'   \code{reshape2::dcast} allows. This is a reasonably simple solution using
#'   built-in functions.
#' @param x data.frame of long-form data, one column for visit_name and one for
#'   ICD code
#' @template visit_name
#' @template icd_name
#' @param prefix character, default \code{icd_} to prefix new columns
#' @param min_width, single integer, if specified, writes out this many columns
#'   even if no patients have that many codes. Must be greater than or equal to
#'   the maximum number of codes per patient.
#' @examples
#' longdf <- data.frame(
#'   visit_name = c("a", "b", "b", "c"),
#'   icd9 = c("441", "4424", "443", "441")
#' )
#' long_to_wide(longdf)
#' long_to_wide(longdf, prefix = "ICD10_")
#' @family ICD data conversion
#' @export
long_to_wide <- function(x,
                         visit_name = get_visit_name(x),
                         icd_name = get_icd_name(x),
                         prefix = "icd_",
                         min_width = 1L) {
  assert_data_frame(x, col.names = "unique")
  visit_name <- as_char_no_warn(visit_name)
  icd_name <- as_char_no_warn(icd_name)
  stopifnot(visit_name %in% names(x))
  stopifnot(icd_name %in% names(x))
  stopifnot(is.character(prefix), length(prefix) == 1, nchar(prefix) > 0)
  stopifnot(all(min_width > 0), length(min_width) == 1)
  visit_name_f <- is.factor(x[[visit_name]])
  icd_name_f <- is.factor(x[[icd_name]])
  if (icd_name_f) i_levels <- levels(x[[icd_name]])
  x_order <- order(x[[visit_name]])
  x <- x[x_order, ]
  if (visit_name_f) {
    v_levels <- levels(x[[visit_name]])
  } else {
    v_levels <- x[!duplicated(x[[visit_name]]), visit_name]
  }
  x$seqnum <- sequence(tabulate(factor(x[[visit_name]], levels = v_levels)))
  out <- reshape(x[c(visit_name, "seqnum", icd_name)],
    idvar = visit_name,
    timevar = "seqnum",
    direction = "wide"
  )
  if (visit_name_f) {
    out[[visit_name]] <- factor(x = out[[visit_name]], levels = v_levels)
  }
  if (icd_name_f) {
    out[-which(names(out) == visit_name)] <-
      lapply(out[-which(names(out) == visit_name)], factor, levels = i_levels)
  }
  nc <- ncol(out) - 1
  names(out)[-which(names(out) == visit_name)] <-
    paste(prefix, sprintf("%03d", 1:nc), sep = "")
  if (nc < min_width) {
    out <- cbind(out, matrix(NA, ncol = min_width - nc))
    nc <- min_width
  }
  names(out)[-1] <- paste(prefix, sprintf("%03d", 1:nc), sep = "")
  as.icd_wide_data(out, warn = FALSE)
}

#' convert comorbidity data frame from matrix
#'
#' convert matrix of comorbidities into data frame, preserving visit_name
#' information
#' @param x Matrix of comorbidities, with row and columns names defined
#' @param visit_name Single character string with name for new column in output
#'   data frame. Everywhere else, \code{visit_name} describes the input data,
#'   but here it is for output data.
#' @template stringsAsFactors
#' @examples
#' longdf <- icd_long_data(
#'   visit_id = c("a", "b", "b", "c"),
#'   icd9 = as.icd9(c("441", "4240", "443", "441"))
#' )
#' mat <- icd9_comorbid_elix(longdf)
#' class(mat)
#' typeof(mat)
#' rownames(mat)
#' df.out <- comorbid_mat_to_df(mat)
#' stopifnot(is.data.frame(df.out))
#' # output data frame has a factor for the visit_name column
#' stopifnot(identical(rownames(mat), as.character(df.out[["visit_id"]])))
#' df.out[, 1:4]
#' # when creating a data frame like this, stringsAsFactors uses
#' # the system-wide option you may have set e.g. with
#' # options("stringsAsFactors" = FALSE).
#' is.factor(df.out[["visit_id"]])
#' @family ICD data conversion
#' @seealso \code{\link{comorbid_df_to_mat}}
#' @export
comorbid_mat_to_df <- function(x, visit_name = "visit_id",
                               stringsAsFactors = getOption("stringsAsFactors")) { # nolint
  assert_matrix(x,
    min.rows = 1, min.cols = 1,
    row.names = "named", col.names = "named"
  )
  assert_string(visit_name)
  assert_flag(stringsAsFactors) # nolint
  out <- data.frame(rownames(x), x, stringsAsFactors = stringsAsFactors, row.names = NULL) # nolint
  names(out)[1] <- visit_name
  rownames(out) <- NULL
  out
}

#' convert comorbidity matrix to data frame
#'
#' convert matrix of comorbidities into data frame, preserving visit_name
#' information
#' @param x data frame, with a \code{visit_name} column (not necessarily first),
#'   and other columns with flags for comorbidities, as such column names are
#'   required.
#' @template visit_name
#' @template stringsAsFactors
#' @examples
#' longdf <- icd_long_data(
#'   visit = c("a", "b", "b", "c"),
#'   icd9 = c("441", "4240", "443", "441")
#' )
#' cmbdf <- icd9_comorbid_elix(longdf, return_df = TRUE)
#' class(cmbdf)
#' rownames(cmbdf)
#' mat.out <- comorbid_df_to_mat(cmbdf)
#' stopifnot(is.matrix(mat.out))
#' mat.out[, 1:4]
#' @family ICD data conversion
#' @seealso \code{\link{comorbid_mat_to_df}}
#' @export
comorbid_df_to_mat <- function(x, visit_name = get_visit_name(x),
                               stringsAsFactors = getOption("stringsAsFactors")) { # nolint
  assert_data_frame(x, min.rows = 1, min.cols = 2, col.names = "named")
  assert_string(visit_name)
  assert_flag(stringsAsFactors) # nolint

  out <- as.matrix.data.frame(x[-which(names(x) == visit_name)])
  rownames(out) <- x[[visit_name]]
  out
}

#' Convert ICD codes from short to decimal forms
#'
#' Convert from short to decimal forms of ICD codes.
#' @param x ICD codes
#' @export
#' @keywords manip
#' @family ICD data conversion
short_to_decimal <- function(x) {
  UseMethod("short_to_decimal")
}

#' @describeIn short_to_decimal convert ICD codes of unknown type from short
#'   to decimal format
#' @export
#' @keywords internal manip
short_to_decimal.default <- function(x) {
  switch(
    guess_version.character(as_char_no_warn(x), short_code = TRUE),
    "icd9" = short_to_decimal.icd9(x),
    "icd10" = short_to_decimal.icd10(x),
    stop("ICD type not known")
  )
}

#' @describeIn short_to_decimal convert ICD-9 codes from short to decimal
#'   format
#' @export
#' @keywords internal manip
short_to_decimal.icd9 <- function(x) {
  icd9(as.decimal_diag(icd9_short_to_decimal_rcpp(x)))
}

#' @describeIn short_to_decimal convert ICD-10 codes from short to decimal
#'   format
#' @export
#' @keywords internal manip
short_to_decimal.icd10 <- function(x) {
  x <- trimws(x)
  out <- substr(x, 0, 3) # majors
  minors <- substr(x, 4, 100L)
  out[minors != ""] <- paste0(out[minors != ""], ".", minors[minors != ""])
  icd10(as.decimal_diag(out)) # not as.icd10
}

#' @describeIn short_to_decimal convert ICD-10-CM code from short to decimal
#'   format
#' @export
#' @keywords internal manip
short_to_decimal.icd10cm <- function(x) {
  as.icd10cm(short_to_decimal.icd10(x))
}

#' Convert Decimal format ICD codes to short format
#'
#' This usually just entails removing the decimal point, but also does some
#' limited validation and tidying up. Missing leading zeroes will be added for
#' correctness of the shortened codes.
#'
#' @param x ICD codes
#' @export
#' @keywords manip
#' @family ICD data conversion
decimal_to_short <- function(x) {
  UseMethod("decimal_to_short")
}

#' @describeIn decimal_to_short convert ICD-9 codes from decimal to short
#'   format
#' @export
#' @keywords internal manip
decimal_to_short.icd9 <- function(x) {
  if (is.factor(x)) {
    levels(x) <- icd9(as.short_diag(icd9_decimal_to_short_rcpp(levels(x))))
    return(x)
  }
  icd9(as.short_diag(icd9_decimal_to_short_rcpp(x)))
}

#' @describeIn decimal_to_short convert ICD-10 codes from decimal to short
#'   format
#' @export
#' @keywords internal manip
decimal_to_short.icd10 <- function(x) {
  if (is.factor(x)) {
    levels(x) <- gsub("\\.", "", levels(x))
    return(icd10(as.short_diag(x)))
  }
  icd10(as.short_diag(gsub("\\.", "", x))) # not as.icd10
}

#' @describeIn decimal_to_short convert ICD-10-CM codes from decimal to short
#'   format
#' @export
#' @keywords internal manip
decimal_to_short.icd10cm <- function(x)
  as.icd10cm(decimal_to_short.icd10(x))

#' @describeIn decimal_to_short Guess ICD version and convert decimal to
#'   short format
#' @export
#' @keywords internal manip
decimal_to_short.default <- function(x) {
  switch(
    guess_version(as_char_no_warn(x), short_code = FALSE),
    "icd9" = decimal_to_short.icd9(x),
    "icd10" = decimal_to_short.icd10(x),
    stop("Unknown ICD version guessed from input")
  )
}

#' Convert short format ICD codes to component parts
#' @keywords internal manip
#' @noRd
short_to_parts <- function(x, mnr_empty = "") {
  UseMethod("short_to_parts")
}

#' @describeIn short_to_parts Convert short format ICD-9 codes to parts
#' @export
#' @keywords internal manip
#' @noRd
short_to_parts.icd9 <- function(x, mnr_empty = "") {
  # Cannot specify default values in both header and C++ function body, so use a
  # shim here.
  icd9ShortToParts(x, mnrEmpty = mnr_empty)
}

#' @describeIn short_to_parts Convert short format ICD-10 codes to parts
#' @export
#' @keywords internal manip
#' @noRd
short_to_parts.icd10 <- function(x, mnr_empty = "") {
  icd10_short_to_parts_rcpp(x, mnrEmpty = mnr_empty)
}

#' @describeIn short_to_parts Convert short format ICD-10-CM codes to parts
#' @export
#' @keywords internal manip
#' @noRd
short_to_parts.icd10cm <- function(x, mnr_empty = "") {
  icd10_short_to_parts_rcpp(x, mnrEmpty = mnr_empty)
}

#' @describeIn short_to_parts Convert short format ICD code to parts,
#'   guessing whether ICD-9 or ICD-10
#' @export
#' @keywords internal manip
#' @noRd
short_to_parts.character <- function(x, mnr_empty = "")
# No default values in header plus C++ function body, so shim here.
  switch(
    guess_version(x, short_code = TRUE),
    "icd9" = icd9ShortToParts(x, mnrEmpty = mnr_empty),
    "icd10" = short_to_parts.icd10(x, mnr_empty = mnr_empty),
    stop("Unknown ICD version guessed from input")
  )

#' Convert decimal ICD codes to component parts
#' @keywords internal manip
#' @noRd
decimal_to_parts <- function(x, mnr_empty = "") {
  UseMethod("decimal_to_parts")
}

#' @describeIn decimal_to_parts Convert decimal ICD-9 code to parts
#' @export
#' @keywords internal manip
#' @noRd
decimal_to_parts.icd9 <- function(x, mnr_empty = "") {
  icd9DecimalToParts(x, mnrEmpty = mnr_empty)
}

#' @describeIn decimal_to_parts Convert decimal ICD code to parts, guessing
#'   ICD version
#' @export
#' @keywords internal manip
#' @noRd
decimal_to_parts.character <- function(x, mnr_empty = "") {
  switch(
    guess_version(x, short_code = FALSE),
    "icd9" = icd9DecimalToParts(x, mnr_empty),
    "icd10" = decimal_to_parts.icd10(x, mnr_empty = mnr_empty),
    stop("Unknown ICD version guessed from input")
  )
}

#' @describeIn decimal_to_parts Convert decimal ICD-10 code to parts. This
#'   shares almost 100% code with the ICD-9 version: someday combine the common
#'   code.
#' @export
#' @keywords internal manip
#' @noRd
decimal_to_parts.icd10 <- function(x, mnr_empty = "") {
  icd10DecimalToParts(x, mnrEmpty = mnr_empty)
}
