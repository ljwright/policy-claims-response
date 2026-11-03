library(tidyverse)
library(readxl)
library(glue)
library(fs)

rm(list = ls())

dir_create("output/step_03")
dir_create("data/external")

# 1. Load Data and Create Helpers ----
classifications <- readRDS("data/step_02/classifications.Rds")
scopus_corpus <- readRDS("data/step_01/scopus_corpus.Rds")

prob_models <- c("deepseek_v41_flash", "jev_114")

model_lookup <- c(deepseek_v31 = "DeepSeek V3.1",
                  deepseek_v41_flash = "DeepSeek V4.1 Flash",
                  jev_114 = "Jev v1.14")
prompt_lookup <- c(original = "Original",
                   new = "New (More Detailed)")

loess_span <- 0.5

cbbPalette <- c("#000000", "#E69F00", "#56B4E9", "#009E73",
                "#F0E442", "#0072B2", "#D55E00", "#CC79A7")

# Share of each human-coded group whose P(claim) falls in each tenth (0-0.1,
# 0.1-0.2, ...), by model and prompt. Bars rather than densities, as DeepSeek's
# probabilities are almost all exactly 0 or 1.
plot_p_bars <- function(df, fill_title) {
  df %>%
    mutate(p_bin = pmin(floor(p_claim * 10), 9) / 10 + 0.05) %>% # Bin midpoint
    count(model_clean, prompt_clean, coding, p_bin) %>%
    mutate(pct = 100 * n / sum(n), .by = c(model_clean, prompt_clean, coding)) %>%
    ggplot(aes(x = p_bin, y = pct, fill = coding)) +
    geom_col(position = position_dodge(preserve = "single"), width = 0.09) +
    facet_grid(prompt_clean ~ model_clean) +
    scale_x_continuous(breaks = seq(0, 1, 0.2), limits = c(0, 1)) +
    scale_fill_manual(values = group_colours) +
    labs(x = "P(policy claim)", y = "Share of group (%)", fill = fill_title) +
    theme_minimal() +
    theme(legend.position = "bottom", panel.grid.minor = element_blank())
}

# 2. Policy Claims Over Time ----
classifications %>%
  select(spec_id, scopus_id, model_name, prompt_name, label, p_claim) %>%
  left_join(scopus_corpus %>%
              select(scopus_id, abbrev, year),
            by = "scopus_id") %>%
  group_by(model_name, prompt_name, year) %>%
  summarise(p_claim = mean(label),
            .groups = "drop") %>%
  mutate(model_clean = model_lookup[model_name],
         prompt_clean = factor(prompt_lookup[prompt_name], levels = prompt_lookup)) %>%
  ggplot() +
  aes(x = year, y = p_claim, 
      color = model_clean, linetype = prompt_clean) +
  geom_smooth(method = "loess", formula = y ~ x, 
              span = loess_span, se = FALSE) +
  scale_colour_manual(values = cbbPalette[c(4, 6, 8)]) +
  scale_y_continuous(limits = c(0, NA), labels = scales::percent) +
  labs(x = "Publication Year", y = "Abstracts\nwith a\nPolicy\nClaim",
       colour = "LLM", linetype = "Prompt") +
  theme_minimal() +
  theme(axis.title.y = element_text(angle = 0, vjust = 0.5),
        legend.position = "bottom", 
        legend.box = "vertical")
ggsave("output/step_03/trends.png",
       width = 16, height = 9.9, units = "cm",
       dpi = 300, bg = "white")

# 3. Disagreement ----
epi_coding <- read_csv("../Notes/epidemiology_policy_claims_review.csv",
                       col_types = cols(.default = "c")) %>%
  filter(flag_call_to_action %in% c("0", "1")) %>%
  transmute(doi = str_to_lower(str_trim(doi)),
            coding = if_else(flag_call_to_action == "1",
                             "Claim", 
                             "No Claim") %>%
              factor()) %>%
  left_join(scopus_corpus %>%
              select(scopus_id, doi) %>%
              mutate(doi = str_to_lower(str_trim(doi))),
            by = "doi") %>%
  drop_na()

classifications %>%
  filter(model_name == "jev_114",
         !is.na(p_claim)) %>%
  select(spec_id, model_name, prompt_name, scopus_id, p_claim) %>%
  inner_join(epi_coding,
             by = "scopus_id") %>%
  mutate(model_clean = model_lookup[model_name],
         prompt_clean = factor(prompt_lookup[prompt_name], levels = prompt_lookup) %>%
           fct_relabel(~ paste0(.x, " Prompt"))) %>%
  ggplot() +
  aes(x = p_claim, 
      y = after_stat(ifelse(count == 0, NA, density)),
      fill = coding) +
  facet_grid(~ prompt_clean) +
  geom_histogram(position = "identity", alpha = 0.7) +
  scale_x_continuous(limits = c(0, 1)) +
  scale_fill_manual(values = cbbPalette[c(6, 2)]) +
  theme_bw() +
  theme(legend.position = "bottom") +
  labs(x = "Probability Abstract Contains Policy Claim (Jev v1.14)",
       y = "Density",
       fill = "Cartus et al. Coding")
ggsave("output/step_03/epidemiology_probabilities.png",
       width = 16, height = 9.9, units = "cm",
       dpi = 300, bg = "white")