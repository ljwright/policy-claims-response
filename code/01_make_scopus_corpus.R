library(tidyverse)
library(httr2)
library(tictoc)
library(glue)
library(fs)

rm(list = ls())

dir_create("data/step_01")

# 1. Load Data and Create Helpers ----
scopus_api_key <- Sys.getenv("SCOPUS_API_KEY")
scopus_requests_per_second <- 9 # Scopus Search API limit per key (and 20,000 a week)

journal_dict <- tribble(
  ~abbrev,                   ~issn,       ~journal_name,                                  ~short_name,
  "int_j_epidemiol",         "0300-5771", "International Journal of Epidemiology",        "Int J Epidemiol",
  "am_j_prev_med",           "0749-3797", "American Journal of Preventive Medicine",      "Am J Prev Med",
  "prev_med",                "0091-7435", "Preventive Medicine",                          "Prev Med",
  "epidemiology",            "1044-3983", "Epidemiology",                                 "Epidemiology",
  "j_epidemiol_comm_health", "0143-005X", "Journal of Epidemiology and Community Health", "J Epidemiol Community Health",
  "lancet_public_health",    "2468-2667", "The Lancet Public Health",                     "Lancet Public Health",
  "am_j_public_health",      "0090-0036", "American Journal of Public Health",            "Am J Public Health",
  "eur_j_public_health",     "1101-1262", "European Journal of Public Health",            "Eur J Public Health",
  "am_j_epidemiol",          "0002-9262", "American Journal of Epidemiology",             "Am J Epidemiol",
  "eur_j_epidemiol",         "0393-2990", "European Journal of Epidemiology",             "Eur J Epidemiol"
)
saveRDS(journal_dict, "data/step_01/journal_dict.Rds")

scopus_spec <- journal_dict %>%
  select(-journal_name) %>%
  expand_grid(year = 1990:2024)

scopus_error_text <- function(resp){
  tryCatch(resp_body_json(resp)$`service-error`$status$statusText,
           error = \(e) NULL)
}

scopus_request <- request("https://api.elsevier.com/content/search/scopus") %>%
  req_headers(`X-ELS-APIKey` = scopus_api_key, 
              Accept = "application/json",
              .redact = "X-ELS-APIKey") %>%
  req_throttle(capacity = scopus_requests_per_second, fill_time_s = 1) %>%
  req_retry(max_tries = 5,
            retry_on_failure = TRUE,
            is_transient = ~ resp_status(.x) %in% c(429, 500, 502, 503, 504) &&
              !identical(resp_header(.x, "X-ELS-Status"), "QUOTA_EXCEEDED")) %>%
  req_timeout(120) %>%
  req_error(body = scopus_error_text)

scopus_query <- function(issn, year) str_glue("ISSN({issn}) AND PUBYEAR = {year} AND DOCTYPE(ar)")

# 2. Make Scopus Requests ----
# A journal-year's pages must come one after another (each page holds the cursor
# for the next), so the journal-years run in parallel instead: page 1 of every
# journal-year, then page 2 of those with more, and so on.
first_page <- function(issn, year) {
  scopus_request %>%
    req_url_query(query = scopus_query(issn, year),
                  view = "COMPLETE",
                  count = 25,
                  cursor = "*")
}

next_page <- function(resp, req) {
  if (!inherits(resp, "httr2_response")) return(NULL) # failed: rerun this journal-year
  results <- resp_body_json(resp)[["search-results"]]
  next_cursor <- results[["cursor"]][["@next"]]
  if (length(results$entry) < 25 || is.null(next_cursor)) return(NULL)
  req_url_query(req, cursor = next_cursor)
}

tic()
to_fetch <- scopus_spec %>%
  mutate(page = 1, req = map2(issn, year, first_page))
scopus_resps <- list()

while (nrow(to_fetch) > 0) {
  resps <- req_perform_parallel(to_fetch$req, on_error = "continue", max_active = 20)
  ok <- map_lgl(resps, ~ inherits(.x, "httr2_response"))
  message(str_glue("Page {to_fetch$page[1]}: {sum(ok)} of {length(ok)} requests succeeded"))
  
  scopus_resps <- c(scopus_resps, list(mutate(to_fetch, resp = resps)))
  to_fetch <- to_fetch %>%
    mutate(page = page + 1, req = map2(resps, req, next_page)) %>%
    filter(!map_lgl(req, is.null))
}

scopus_resps <- bind_rows(scopus_resps) %>% select(-req)
toc()
saveRDS(scopus_resps, "data/step_01/scopus_resps.Rds")

# 3. Parse Scopus Records ----
scopus_resps <- readRDS("data/step_01/scopus_resps.Rds")

# One search result to one row. `country` is the first listed affiliation's
# country (the original script called it corresponding_author_country; the
# paper reports it as the first author's country).
parse_scopus_entry <- function(entry) {
  if (!is.null(entry$error)) return(NULL) # "Result set was empty"
  affiliations <- entry$affiliation
  country <- if (length(affiliations) > 0) affiliations[[1]][["affiliation-country"]]
  keywords <- entry$authkeywords
  
  tibble(
    scopus_id = entry[["dc:identifier"]] %||% NA_character_,
    doi = entry[["prism:doi"]] %||% NA_character_,
    title = entry[["dc:title"]] %||% NA_character_,
    journal = entry[["prism:publicationName"]] %||% NA_character_,
    publication_year = as.integer(str_sub(entry[["prism:coverDate"]] %||% NA_character_, 1, 4)),
    keywords = if (is.null(keywords) || keywords == "") {
      NA_character_
    } else {
      str_replace_all(keywords, fixed(" | "), "; ")
    },
    abstract = entry[["dc:description"]] %||% NA_character_,
    article_type = str_to_lower(entry$subtypeDescription %||% ""),
    country = country %||% "Unknown",
    cited_by_count = as.integer(entry[["citedby-count"]] %||% NA)
  )
}

scopus_pages <- scopus_resps %>%
  filter(map_lgl(resp, ~ inherits(.x, "httr2_response"))) %>%
  mutate(results = map(resp, ~ resp_body_json(.x)[["search-results"]]),
         scopus_total = map_int(results, ~ as.integer(.x[["opensearch:totalResults"]])))

scopus_records <- scopus_pages %>%
  mutate(records = map(results, ~ list_rbind(map(.x$entry, parse_scopus_entry)))) %>%
  select(abbrev, issn, year, page, records) %>%
  unnest(records)

# Journal-years with a failed page, or fewer records than Scopus reported, are
# incomplete: rerun section 2 for them.
scopus_check <- scopus_pages %>%
  summarise(scopus_total = first(scopus_total), .by = c(abbrev, year)) %>%
  full_join(count(scopus_records, abbrev, year, name = "downloaded"), by = c("abbrev", "year")) %>%
  right_join(distinct(scopus_resps, abbrev, year), by = c("abbrev", "year")) %>%
  mutate(downloaded = coalesce(downloaded, 0L),
         complete = !is.na(scopus_total) & downloaded >= scopus_total)

scopus_check %>%
  filter(complete == FALSE)

# A few articles are listed under two journal-years; keep each once.
scopus_records <- distinct(scopus_records, scopus_id, .keep_all = TRUE)

message(str_glue("{nrow(scopus_records)} records from {nrow(scopus_check)} journal-years; ",
                 "{sum(!scopus_check$complete)} journal-years incomplete."))

saveRDS(scopus_records, "data/step_01/scopus_records.Rds")

# 4. Apply the Paper's Exclusions ----
scopus_records <- readRDS("data/step_01/scopus_records.Rds")

REVIEW_RE <- regex(
  paste0("(\\b(systematic|scoping|umbrella|narrative|rapid)\\s+review(s)?\\b)",
         "|\\bmeta-?analysis(es)?\\b",
         "|\\b(review|reviews)\\b"),
  ignore_case = TRUE
)
COMMENTARY_TITLE_RE <- regex(
  "\\b(comment(ary)?|authors?\\s*reply|response|letter)\\b",
  ignore_case = TRUE
)
COMMENTARY_ABSTRACT_RE <- regex(
  "\\b(this\\s+commentary|authors?\\s+reply|in\\s+response\\s+to)\\b",
  ignore_case = TRUE
)
min_abstract_chars <- 30

nfkc_squish <- function(x) str_squish(stringi::stri_trans_nfkc(coalesce(x, "")))

scopus_screened <- scopus_records %>%
  mutate(
    title_clean = nfkc_squish(title),
    abstract_clean = nfkc_squish(abstract),
    keywords_clean = nfkc_squish(keywords),
    exclusion = case_when(
      abstract_clean == "" ~ "empty abstract",
      str_detect(title_clean, REVIEW_RE) | str_detect(keywords_clean, REVIEW_RE) ~ "review",
      str_detect(title_clean, COMMENTARY_TITLE_RE) ~ "commentary (title)",
      str_detect(abstract_clean, COMMENTARY_ABSTRACT_RE) ~ "commentary (abstract)",
      str_length(str_trim(abstract)) < min_abstract_chars ~ "abstract under 30 characters",
      !publication_year %in% 1990:2024 ~ "outside 1990-2024"
    )
  ) %>%
  select(-title_clean, -abstract_clean, -keywords_clean)

count(scopus_screened, exclusion)

scopus_corpus <- scopus_screened %>%
  filter(is.na(exclusion)) %>%
  select(-exclusion)

message(str_glue("{nrow(scopus_corpus)} abstracts kept (paper: 45,807)."))

saveRDS(scopus_corpus, "data/step_01/scopus_corpus.Rds")
