library(tidyverse)
library(httr2)
library(glue)
library(fs)
library(tictoc)

rm(list = ls())

dir_create("data/step_02")

# 1. Load Data and Create Helpers ----
args <- commandArgs(trailingOnly = TRUE)

openrouter_api_key <- Sys.getenv("OPENROUTER_API_KEY")
n_abstracts <- Inf # Set to e.g. 20 to try each specification on a few abstracts first

scopus_corpus <- readRDS("data/step_01/scopus_corpus.Rds") %>%
  head(n_abstracts)

# Settings from the paper's code/3_run_llm_classification.py
system_prompt <- "You are an expert academic classifier that only returns JSON."
temperature <- 0.1
max_tokens <- 60

# DeepSeek V3.1 (the paper's model) and V4.1 Flash run on hosts serving the
# original FP8 weights, cheapest first; this account's privacy settings exclude
# DeepSeek's own API. Jev uses OpenRouter's Decisions API, which returns P(claim).
fp8_hosts <- list(quantizations = list("fp8"), 
                  sort = "price", 
                  require_parameters = TRUE)

# For token probabilities, only FP8 hosts that return them for the whole answer
# (Morph lists them but stops after the first four tokens, before true/false).
logprob_hosts <- list(only = list("makora", "streamlake", "novita", "stepfun"),
                      quantizations = list("fp8"), 
                      sort = "price", 
                      require_parameters = TRUE)

models <- tribble(
  ~model_name,          ~api,       ~model,                              ~logprobs,
  "deepseek_v31",       "chat",     "deepseek/deepseek-chat-v3.1",       FALSE,
  "deepseek_v41_flash", "chat",     "deepseek/deepseek-v4.1-flash-1017", TRUE,
  "jev_114",            "decision", "typesafe/jev-1.14-20261014",        FALSE
)

# One specification per model and prompt. The decision prompts are the chat
# prompts without the JSON output instructions, with the abstract passed
# separately (prompts/*_decision.txt).
model_specs <- models %>%
  expand_grid(prompt_name = c("original", "new")) %>%
  mutate(prompt_file = glue("prompts/{prompt_name}_{api}.txt"),
         spec_id = row_number(), .before = 1)

# The Decisions API asks a yes/no question; these replace the JSON answers.
decision_criteria <- list(
  `true` = 'It makes a policy claim (OUTPUT: {"policy_claim": true}).',
  `false` = 'It does not make a policy claim (OUTPUT: {"policy_claim": false}).'
)

openrouter_request <- request("https://openrouter.ai/api") %>%
  req_auth_bearer_token(openrouter_api_key) %>%
  req_throttle(capacity = 30, fill_time_s = 1) %>% # At most 30 requests start each second
  req_retry(max_tries = 4,
            retry_on_failure = TRUE,
            is_transient = ~ resp_status(.x) %in% c(408, 429, 500, 502, 503, 504)) %>%
  req_timeout(120) %>%
  req_error(is_error = ~ FALSE) # Keep error responses so they are saved and retried

# 2. Build Requests ----
# The fixed prompt comes first and the abstract last, so hosts can cache the
# shared part of the prompt and charge less for it.
fill_prompt <- function(prompt, abstract) {
  parts <- str_split_1(prompt, fixed("{abstract}"))
  paste0(parts[1], abstract, parts[2])
}

chat_request <- function(abstract, spec, prompt) {
  body <- list(
    model = spec$model,
    messages = list(
      list(role = "system", content = system_prompt),
      list(role = "user", content = fill_prompt(prompt, abstract))
    ),
    temperature = temperature,
    max_tokens = max_tokens,
    response_format = list(type = "json_object"),
    reasoning = list(enabled = FALSE), # Non-thinking mode, as in the paper
    usage = list(include = TRUE),
    provider = if (spec$logprobs) logprob_hosts else fp8_hosts
  )
  if (spec$logprobs) body <- c(body, list(logprobs = TRUE, top_logprobs = 5))
  
  openrouter_request %>%
    req_url_path_append("v1/chat/completions") %>%
    req_body_json(body)
}

decision_request <- function(abstract, spec, prompt) {
  body <- list(
    model = spec$model,
    state = list(abstract = abstract),
    questions = list(
      policy_claim = list(type = "noul", 
                          instructions = prompt, 
                          criteria = decision_criteria)
    )
  )
  
  openrouter_request %>%
    req_url_path_append("alpha/decisions") %>%
    req_body_json(body)
}

# 3. Make Requests ----
# One specification at a time, with its requests in parallel. Each batch of raw
# responses is saved as it finishes (the JSON body as text, which is all the
# parsing needs), so a rerun only requests abstracts without a successful
# response.
batch_size <- 1000

spec_dir <- function(spec_id) glue("data/step_02/spec_{spec_id}")

read_spec_resps <- function(spec_id) {
  dir_ls(spec_dir(spec_id), glob = "*.Rds") %>%
    map(readRDS) %>%
    list_rbind()
}

request_spec <- function(spec_id) {
  spec <- model_specs %>%
    filter(spec_id == !!spec_id)
  prompt <- read_file(spec$prompt_file)
  make_request <- if (spec$api == "chat") chat_request else decision_request
  dir_create(spec_dir(spec_id))
  
  done <- read_spec_resps(spec_id)
  to_do <- scopus_corpus %>%
    filter(!scopus_id %in% done$scopus_id[done$http_status %in% 200])
  message(glue("Spec {spec_id} ({spec$model_name}, {spec$prompt_name} prompt): ",
               "{nrow(to_do)} abstracts to request"))
  
  batches <- split(to_do, ceiling(seq_len(nrow(to_do)) / batch_size))
  for (i in seq_along(batches)) {
    batch <- batches[[i]]
    resps <- batch$abstract %>%
      map(~ make_request(.x, spec, prompt)) %>%
      req_perform_parallel(on_error = "continue",
                           max_active = 30,
                           progress = FALSE)
    
    batch_resps <- tibble(
      scopus_id = batch$scopus_id,
      http_status = map_int(resps, ~ if (inherits(.x, "httr2_response")) resp_status(.x) else NA_integer_),
      body = map_chr(resps, ~ if (inherits(.x, "httr2_response")) resp_body_string(.x) else conditionMessage(.x))
    )
    saveRDS(batch_resps, glue("{spec_dir(spec_id)}/batch_{format(Sys.time(), '%Y%m%d_%H%M%S')}_{i}.Rds"))
    
    message(glue("  Batch {i}/{length(batches)}: {sum(batch_resps$http_status %in% 200)} ",
                 "of {nrow(batch_resps)} succeeded"))
    # If nothing worked (e.g. no credit left), stop rather than fail every abstract.
    if (!any(batch_resps$http_status %in% 200)) {
      stop(glue("Every request failed, e.g.: {str_trunc(batch_resps$body[1], 300)}"), call. = FALSE)
    }
  }
}

specs_to_run <- model_specs$spec_id
if (length(args) > 0) specs_to_run <- as.integer(args)

tic()
walk(specs_to_run, request_spec)
toc()

# 4. Parse Responses ----
# P(claim) from the token probabilities at the true/false answer.
p_from_logprobs <- function(tokens) {
  answer <- detect(tokens, ~ str_to_lower(str_trim(.x$token)) %in% c("true", "false"))
  if (is.null(answer)) return(NA_real_)
  
  options <- answer$top_logprobs %>%
    map(~ tibble(token = str_to_lower(str_trim(.x$token)),
                 p = exp(.x$logprob))) %>%
    list_rbind()
  p_true <- sum(options$p[options$token == "true"])
  p_false <- sum(options$p[options$token == "false"])
  if (p_true + p_false == 0) return(NA_real_)
  p_true / (p_true + p_false)
}

parse_body <- function(body, api) {
  body <- jsonlite::fromJSON(body, simplifyVector = FALSE)
  
  if (api == "chat") {
    choice <- body$choices[[1]]
    content <- choice$message$content %||% NA_character_
    label <- case_when(
      str_detect(content, '"policy_claim"\\s*:\\s*true') ~ TRUE,
      str_detect(content, '"policy_claim"\\s*:\\s*false') ~ FALSE
    )
    p_claim <- p_from_logprobs(choice$logprobs$content)
  } else {
    content <- NA_character_
    p_claim <- body$answers$policy_claim$noul %||% NA_real_
    label <- p_claim >= 0.5
  }
  
  tibble(
    label = label,
    p_claim = p_claim,
    content = content,
    provider = body$provider %||% NA_character_,
    input_tokens = body$usage$prompt_tokens %||% body$usage$input_tokens %||% NA_real_,
    cached_tokens = body$usage$prompt_tokens_details$cached_tokens %||% NA_real_,
    cost_usd = body$usage$cost %||% NA_real_
  )
}

# The successful response for each abstract in each specification
model_resps <- model_specs %>%
  mutate(resps = map(spec_id, read_spec_resps)) %>%
  unnest(resps) %>%
  filter(http_status %in% 200) %>%
  distinct(spec_id, scopus_id, .keep_all = TRUE)

classifications <- model_resps %>%
  mutate(res = map2(body, api, parse_body)) %>%
  select(-body) %>%
  unnest(res)

classifications %>%
  group_by(model_name, prompt_name) %>%
  summarise(
    abstracts = n(),
    unparseable = sum(is.na(label)),
    claims = mean(label, na.rm = TRUE),
    cost_usd = sum(cost_usd, na.rm = TRUE),
    cached_share = sum(cached_tokens, na.rm = TRUE) / sum(input_tokens, na.rm = TRUE)
  ) %>%
  ungroup()

saveRDS(classifications, "data/step_02/classifications.Rds")
