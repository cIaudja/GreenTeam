# =============================================================================
# Data analysis - json vs orjson (Green Lab 2026/2027)
#
# Synthetic block: RQ1 (library effect on energy) and RQ1.1 (library x payload
# complexity interaction on energy efficiency, J/KB).
#
# Run from the ROOT of the repository:
#   Rscript data-analysis/analysis.R
# or open the repo as a folder in Positron/RStudio and source this file.
#
# Outputs:
#   data-analysis/figures/*.pdf   plots for the report
#   data-analysis/tables/*.csv    tables (also *.tex, ready for Overleaf)
#   data-analysis/processed/      cleaned data used by the analysis
# =============================================================================

# ---- packages ---------------------------------------------------------------
needed <- c("tidyverse", "jsonlite", "ARTool", "xtable")
missing <- needed[!needed %in% rownames(installed.packages())]
if (length(missing) > 0) install.packages(missing, repos = "https://cloud.r-project.org")

suppressPackageStartupMessages({
  library(tidyverse)
  library(jsonlite)
  library(ARTool)
  library(xtable)
})

# ---- settings ---------------------------------------------------------------
SUBTRACT_IDLE <- FALSE   # TRUE = energy minus idle_power_W * execution_time_s
ALPHA <- 0.05
RESULTS_DIR <- "results/json_energy_synthetic"
OUT <- "data-analysis"

if (!file.exists(file.path(RESULTS_DIR, "run_table.csv"))) {
  stop("Run this script from the root of the repository (", RESULTS_DIR, " not found).")
}
for (d in c("figures", "tables", "processed")) dir.create(file.path(OUT, d), showWarnings = FALSE, recursive = TRUE)

save_table <- function(df, name, caption, digits = 3) {
  write_csv(df, file.path(OUT, "tables", paste0(name, ".csv")))
  print(xtable(df, caption = caption, label = paste0("tab:", name), digits = digits),
        file = file.path(OUT, "tables", paste0(name, ".tex")),
        include.rownames = FALSE, booktabs = TRUE)
}

# ---- 1. load data -----------------------------------------------------------
run_table <- read_csv(file.path(RESULTS_DIR, "run_table.csv"), show_col_types = FALSE)

cat("Runs in run table:", nrow(run_table), "\n")
cat("Runs not DONE (to re-execute):", sum(run_table$`__done` != "DONE"), "\n")

# volume actually processed in each run, read from benchmark.json
read_volume <- function(run_id) {
  f <- file.path(RESULTS_DIR, run_id, "benchmark.json")
  if (!file.exists(f)) return(NA_real_)
  fromJSON(f)$volume_bytes
}

dat <- run_table %>%
  filter(`__done` == "DONE") %>%
  mutate(across(c(execution_time_s, cpu_utilisation_pct, peak_memory_bytes, energy_J, idle_power_W),
                as.numeric)) %>%   # TODO rows contain blanks, which make readr read text
  mutate(
    volume_bytes = map_dbl(`__run_id`, read_volume),
    energy_raw_J = energy_J,
    energy_J = if (SUBTRACT_IDLE) energy_J - idle_power_W * execution_time_s else energy_J,
    volume_KB = volume_bytes / 1000,                 # decimal KB, as in the report
    efficiency_J_per_KB = energy_J / volume_KB,
    efficiency_uJ_per_KB = efficiency_J_per_KB * 1e6,  # same measure in microjoules, for readable plots/tables
    power_W = energy_J / execution_time_s,
    library = factor(library, levels = c("json", "orjson")),
    operation = factor(operation, levels = c("dumps", "loads")),
    payload = factor(payload, levels = c("simple", "moderate", "complex"))
  )

write_csv(dat, file.path(OUT, "processed", "synthetic_clean.csv"))

# ---- 2. anomalies and outliers ----------------------------------------------
anomalies <- dat %>%
  summarise(
    missing_volume = sum(is.na(volume_bytes)),
    non_positive_energy = sum(energy_J <= 0),
    non_positive_time = sum(execution_time_s <= 0),
    negative_memory = sum(peak_memory_bytes < 0),
    zero_memory = sum(peak_memory_bytes == 0)
  )
cat("\nAnomaly check:\n"); print(anomalies)

outliers <- dat %>%
  group_by(operation, payload, library) %>%
  mutate(q1 = quantile(energy_J, 0.25), q3 = quantile(energy_J, 0.75), iqr = q3 - q1,
         outlier = energy_J < q1 - 1.5 * iqr | energy_J > q3 + 1.5 * iqr) %>%
  ungroup()
cat("\nOutliers (1.5 x IQR on energy), per configuration:\n")
print(outliers %>% filter(outlier) %>% count(operation, payload, library))

# ---- 3. descriptive statistics ----------------------------------------------
describe <- function(x) c(mean = mean(x), median = median(x), sd = sd(x),
                          min = min(x), max = max(x), var = var(x), cv = sd(x) / mean(x))

descriptives <- dat %>%
  pivot_longer(c(energy_J, efficiency_uJ_per_KB, execution_time_s, power_W, cpu_utilisation_pct),
               names_to = "measure", values_to = "value") %>%
  group_by(measure, operation, payload, library) %>%
  summarise(n = n(), as_tibble_row(describe(value)), .groups = "drop")

save_table(descriptives %>% filter(measure == "energy_J") %>% select(-measure),
           "desc_energy", "Descriptive statistics of energy consumption (J), synthetic block", 1)
save_table(descriptives %>% filter(measure == "efficiency_uJ_per_KB") %>% select(-measure),
           "desc_efficiency", "Descriptive statistics of energy efficiency ($\\mu$J/KB), synthetic block", 2)
write_csv(descriptives, file.path(OUT, "tables", "desc_all.csv"))

# ---- 4. exploration plots ---------------------------------------------------
theme_set(theme_bw(base_size = 11))
lib_colours <- c(json = "#1b9e77", orjson = "#d95f02")

op_labels <- labeller(operation = c(dumps = "Serialisation (dumps)", loads = "Deserialisation (loads)"),
                      payload = c(simple = "Simple", moderate = "Moderate", complex = "Complex"))

# One panel per operation x payload, each with its own y scale: the differences
# between libraries are so large that on a shared scale the distributions are flat lines.
violin_plot <- function(y, y_label) {
  ggplot(dat, aes(x = library, y = .data[[y]], fill = library)) +
    geom_violin(alpha = 0.5, scale = "width", trim = FALSE) +
    geom_boxplot(width = 0.15, outlier.size = 0.8, fill = "white") +
    facet_wrap(~ operation + payload, scales = "free_y", nrow = 2, labeller = op_labels) +
    scale_fill_manual(values = lib_colours, guide = "none") +
    labs(x = "Library", y = y_label)
}
p_violin <- violin_plot("efficiency_uJ_per_KB", expression("Energy efficiency (" * mu * "J/KB)"))
ggsave(file.path(OUT, "figures", "violin_efficiency.pdf"), p_violin, width = 7, height = 5)

p_energy <- violin_plot("energy_J", "Energy consumption (J)")
ggsave(file.path(OUT, "figures", "violin_energy.pdf"), p_energy, width = 7, height = 5)

p_density <- ggplot(dat, aes(x = efficiency_uJ_per_KB, fill = library)) +
  geom_density(alpha = 0.5) +
  facet_wrap(~ operation + payload + library, scales = "free", nrow = 2,
             labeller = labeller(.multi_line = FALSE)) +
  scale_fill_manual(values = lib_colours) +
  labs(x = expression("Energy efficiency (" * mu * "J/KB)"), y = "Density", fill = "Library") +
  theme(axis.text.x = element_text(size = 7), strip.text = element_text(size = 8))
ggsave(file.path(OUT, "figures", "density_efficiency.pdf"), p_density, width = 11, height = 4.5)

# ---- 5. normality and homogeneity of variance --------------------------------
# Brown-Forsythe version of Levene's test (same as car::leveneTest, center = median)
levene_p <- function(y, g) {
  dev <- abs(y - ave(y, g, FUN = median))
  anova(lm(dev ~ g))[["Pr(>F)"]][1]
}

normality <- dat %>%
  group_by(operation, payload, library) %>%
  summarise(shapiro_p_raw = shapiro.test(efficiency_J_per_KB)$p.value,
            shapiro_p_log = shapiro.test(log(efficiency_J_per_KB))$p.value,
            .groups = "drop") %>%
  mutate(normal_raw = shapiro_p_raw > ALPHA, normal_log = shapiro_p_log > ALPHA)
save_table(normality, "normality", "Shapiro-Wilk p-values per configuration (raw and log-transformed)", 4)

homogeneity <- dat %>%
  group_by(operation) %>%
  summarise(levene_p = levene_p(efficiency_J_per_KB, interaction(library, payload)), .groups = "drop")
cat("\nNormality (Shapiro-Wilk):\n"); print(normality)
cat("\nHomogeneity of variance (Levene, median-centred):\n"); print(homogeneity)

pdf(file.path(OUT, "figures", "qqplots.pdf"), width = 9, height = 6)
par(mfrow = c(2, 6), mar = c(3, 3, 2, 1))
for (g in split(dat, list(dat$library, dat$payload, dat$operation), drop = TRUE)) {
  qqnorm(g$efficiency_J_per_KB, main = paste(g$operation[1], g$payload[1], g$library[1]), cex.main = 0.8)
  qqline(g$efficiency_J_per_KB)
}
dev.off()

# ---- 6. hypothesis testing --------------------------------------------------
# Effect sizes
cliffs_delta <- function(x, y) mean(sign(outer(x, y, "-")))
cohens_d <- function(x, y) (mean(x) - mean(y)) / sqrt(((length(x) - 1) * var(x) + (length(y) - 1) * var(y)) /
                                                       (length(x) + length(y) - 2))
cliff_magnitude <- function(d) cut(abs(d), c(-Inf, 0.147, 0.33, 0.474, Inf),
                                   labels = c("negligible", "small", "medium", "large"))

anova_rows <- list()
pairwise_rows <- list()

for (op in levels(dat$operation)) {
  d <- dat %>% filter(operation == op)
  all_normal <- all(normality$normal_raw[normality$operation == op])
  equal_var <- homogeneity$levene_p[homogeneity$operation == op] > ALPHA
  parametric <- all_normal && equal_var

  # RQ1 (H0^1, main effect of library) and RQ1.1 (H0^1.1, interaction)
  if (parametric) {
    a <- as.data.frame(anova(lm(efficiency_J_per_KB ~ library * payload, data = d)))
    a <- a[rownames(a) != "Residuals", ]
    terms <- rownames(a); f <- a[["F value"]]; df1 <- a[["Df"]]
    df2 <- df.residual(lm(efficiency_J_per_KB ~ library * payload, data = d)); p <- a[["Pr(>F)"]]
    test_name <- "two-way ANOVA"
  } else {
    a <- as.data.frame(anova(art(efficiency_J_per_KB ~ library * payload, data = d)))
    terms <- if ("Term" %in% names(a)) as.character(a$Term) else rownames(a)
    f <- a[[grep("^F", names(a))[1]]]; df1 <- a[["Df"]]; df2 <- a[["Df.res"]]
    p <- a[[grep("^Pr", names(a))[1]]]
    test_name <- "ART ANOVA"
  }
  anova_rows[[op]] <- tibble(operation = op, test = test_name, term = terms, F = f,
                             df1 = df1, df2 = df2, p = p,
                             partial_eta2 = (f * df1) / (f * df1 + df2))

  # Per complexity level: H0^1(c), json vs orjson
  for (pl in levels(d$payload)) {
    x <- d$efficiency_J_per_KB[d$library == "json" & d$payload == pl]
    y <- d$efficiency_J_per_KB[d$library == "orjson" & d$payload == pl]
    if (parametric) {
      tst <- t.test(x, y, var.equal = FALSE); tname <- "Welch t-test"
    } else {
      tst <- wilcox.test(x, y, exact = FALSE); tname <- "Mann-Whitney U"
    }
    cd <- cliffs_delta(x, y)
    pairwise_rows[[paste(op, pl)]] <- tibble(
      operation = op, payload = pl, test = tname, n_json = length(x), n_orjson = length(y),
      median_json = median(x), median_orjson = median(y),
      rel_diff_pct = 100 * (median(y) - median(x)) / median(x),   # orjson vs json
      ratio_json_over_orjson = median(x) / median(y),
      p = tst$p.value, cliffs_delta = cd, cliff_magnitude = as.character(cliff_magnitude(cd)),
      cohens_d = cohens_d(x, y))
  }
}

anova_res <- bind_rows(anova_rows)
pairwise_res <- bind_rows(pairwise_rows)

# Benjamini-Hochberg correction, jointly over all tests of the synthetic block
all_p <- c(anova_res$p, pairwise_res$p)
all_p_adj <- p.adjust(all_p, method = "BH")
anova_res$p_adj <- all_p_adj[seq_len(nrow(anova_res))]
pairwise_res$p_adj <- all_p_adj[nrow(anova_res) + seq_len(nrow(pairwise_res))]
anova_res$significant <- anova_res$p_adj < ALPHA
pairwise_res$significant <- pairwise_res$p_adj < ALPHA

cat("\nRQ1 / RQ1.1 - factorial test per operation:\n"); print(anova_res)
cat("\nRQ1 per complexity level - json vs orjson:\n"); print(pairwise_res, width = Inf)

save_table(anova_res, "rq1_anova", "RQ1 and RQ1.1: effect of library, payload complexity and their interaction on energy efficiency (BH-adjusted p-values)", 4)
save_table(pairwise_res, "rq1_pairwise", "RQ1 per complexity level: json vs orjson energy efficiency (BH-adjusted p-values)", 4)

# ---- 7. interaction plot (RQ1.1) --------------------------------------------
p_inter <- dat %>%
  group_by(operation, payload, library) %>%
  summarise(median_eff = median(efficiency_uJ_per_KB), .groups = "drop") %>%
  ggplot(aes(x = payload, y = median_eff, colour = library, group = library)) +
  geom_point(size = 2) + geom_line() +
  facet_wrap(~ operation, labeller = op_labels) +
  scale_colour_manual(values = lib_colours) +
  labs(x = "Payload complexity", y = expression("Median energy efficiency (" * mu * "J/KB)"), colour = "Library")
ggsave(file.path(OUT, "figures", "interaction_rq1_1.pdf"), p_inter, width = 7, height = 3.2)

cat("\nDone. Figures in", file.path(OUT, "figures"), "- tables in", file.path(OUT, "tables"), "\n")
