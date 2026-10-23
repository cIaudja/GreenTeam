# =============================================================================
# Data analysis - json vs orjson (Green Lab 2026/2027)
#
# Real-world block: RQ2.1-RQ2.3 (relationship between energy consumption and
# peak RSS, CPU utilisation and execution time) and the supporting comparisons
# H0^S(p, M) between the two libraries on every real-world payload.
#
# Follows Sections 4.3 and 4.5 of the report:
#   - correlations per library x operation x payload, over the 30 runs of
#     that configuration (H0^2.s), and json vs orjson difference (H0^2.s,Delta)
#   - normal data: Pearson + Fisher's z-test; otherwise a log transform is
#     tried first, then Spearman + bootstrap CI of the difference
#   - supporting comparisons: Welch's t-test, or Mann-Whitney U
#   - effect sizes: Cliff's delta / Cohen's d, correlation coefficient,
#     relative difference of the medians
#   - Benjamini-Hochberg correction over all tests of the block
#   - energy E is NOT idle-corrected (Section 4.2); no energy efficiency
#     in this block (V is not fixed)
#
# Input: results/real_world_all.csv (written by experiment-scripts/combine_results.py)
#
# Run from the ROOT of the repository:
#   Rscript data-analysis/analysis_realworld.R
#
# Outputs (next to the synthetic ones, prefixed with rw_ / rq2_):
#   data-analysis/figures/*.pdf, data-analysis/tables/*.csv + *.tex,
#   data-analysis/processed/realworld_clean.csv
# =============================================================================

# ---- packages ---------------------------------------------------------------
needed <- c("tidyverse", "xtable", "scales")
missing <- needed[!needed %in% rownames(installed.packages())]
if (length(missing) > 0) install.packages(missing, repos = "https://cloud.r-project.org")

suppressPackageStartupMessages({
  library(tidyverse)
  library(xtable)
})

# ---- settings ---------------------------------------------------------------
ALPHA  <- 0.05
N_BOOT <- 10000          # bootstrap resamples for the Spearman differences
SEED   <- 2026           # makes the bootstrap reproducible
INPUT  <- "results/real_world_all.csv"
OUT    <- "data-analysis"

PAYLOAD_IDS <- c(github = "R1", twitter = "R2", citm_catalog = "R3", canada = "R4")
MEASURES <- c(E = "Energy (J)", T = "Execution time (s)",
              CPU = "CPU utilisation (%)", RAM = "Peak RSS (MB)")
PERF <- c(RAM = "RQ2.1", CPU = "RQ2.2", T = "RQ2.3")   # X in H0^2.s

if (!file.exists(INPUT)) {
  stop("Run this script from the root of the repository (", INPUT, " not found). ",
       "Create it with: python3 experiment-scripts/combine_results.py --block real-world")
}
for (d in c("figures", "tables", "processed")) dir.create(file.path(OUT, d), showWarnings = FALSE, recursive = TRUE)

save_table <- function(df, name, caption, digits = 3) {
  write_csv(df, file.path(OUT, "tables", paste0(name, ".csv")))
  print(xtable(df, caption = caption, label = paste0("tab:", name), digits = digits),
        file = file.path(OUT, "tables", paste0(name, ".tex")),
        include.rownames = FALSE, booktabs = TRUE)
}

# ---- 1. load data -----------------------------------------------------------
run_table <- read_csv(INPUT, show_col_types = FALSE)
cat("Runs in run table:", nrow(run_table), "\n")
cat("Runs not DONE (to re-execute):", sum(run_table$`__done` != "DONE"), "\n")

dat <- run_table %>%
  filter(`__done` == "DONE") %>%
  mutate(across(c(execution_time_s, cpu_utilisation_pct, energy_J, idle_power_W, peak_rss_bytes),
                as.numeric)) %>%
  transmute(
    run_id = `__run_id`, batch,
    library = factor(library, levels = c("json", "orjson")),
    operation = factor(operation, levels = c("dumps", "loads")),
    payload = factor(PAYLOAD_IDS[payload], levels = PAYLOAD_IDS),
    payload_file = factor(payload, levels = names(PAYLOAD_IDS)),
    E = energy_J,                 # not idle-corrected (Section 4.2)
    T = execution_time_s,
    CPU = cpu_utilisation_pct,
    RAM = peak_rss_bytes / 1e6,   # peak RSS minus baseline, in MB
    idle_power_W
  )

per_config <- dat %>% count(operation, payload, library)
if (nrow(dat) != 480 || any(per_config$n != 30)) {
  warning("Expected 480 runs, 30 per configuration - check the input:\n",
          paste(capture.output(print(per_config %>% filter(n != 30))), collapse = "\n"))
}

# When each run was executed (start of its measurement window, from benchmark.json),
# used to look for time patterns in the outliers (root-cause analysis, Section 4.5).
batch_dir <- function(b) {
  d <- list.files("results", pattern = paste0("^json_energy_real_world_batch", b, "of[0-9]+$"),
                  full.names = TRUE)
  if (length(d) != 1) NA_character_ else d
}
read_start_ms <- function(run_id, b) {
  f <- file.path(batch_dir(b), run_id, "benchmark.json")
  if (is.na(f) || !file.exists(f)) return(NA_real_)
  as.numeric(sub(".*\"start_time_ms\"\\s*:\\s*([0-9.eE+-]+).*", "\\1",
                 paste(readLines(f, warn = FALSE), collapse = " ")))
}
dat <- dat %>%
  mutate(start_ms = map2_dbl(run_id, batch, read_start_ms)) %>%
  group_by(batch) %>%
  mutate(hours_into_batch = (start_ms - min(start_ms, na.rm = TRUE)) / 3.6e6,
         position_in_batch = rank(start_ms, ties.method = "first", na.last = "keep")) %>%
  ungroup()
if (any(is.na(dat$start_ms))) {
  warning(sum(is.na(dat$start_ms)), " runs without benchmark.json: the time plot will skip them")
}
write_csv(dat, file.path(OUT, "processed", "realworld_clean.csv"))

# ---- 2. anomalies and outliers (kept, Section 4.5) --------------------------
anomalies <- dat %>%
  summarise(non_positive_energy = sum(E <= 0), non_positive_time = sum(T <= 0),
            non_positive_rss = sum(RAM <= 0), cpu_above_100 = sum(CPU > 100))
cat("\nAnomaly check:\n"); print(anomalies)

long <- dat %>% pivot_longer(c(E, T, CPU, RAM), names_to = "measure", values_to = "value")

outliers <- long %>%
  group_by(measure, operation, payload, library) %>%
  mutate(q1 = quantile(value, 0.25), q3 = quantile(value, 0.75), iqr = q3 - q1,
         outlier = value < q1 - 1.5 * iqr | value > q3 + 1.5 * iqr) %>%
  ungroup()
outlier_counts <- outliers %>% filter(outlier) %>% count(measure, operation, payload, library)
cat("\nOutliers (1.5 x IQR), per measure and configuration - kept in the analysis:\n")
print(outlier_counts, n = Inf)
write_csv(outlier_counts, file.path(OUT, "tables", "rw_outliers.csv"))

# Every flagged run, with when it ran and how far it lies from its configuration's median
outlier_runs <- outliers %>%
  group_by(measure, operation, payload, library) %>%
  mutate(deviation_pct = 100 * (value / median(value) - 1)) %>%
  ungroup() %>%
  filter(outlier) %>%
  select(measure, operation, payload, library, run_id, batch, position_in_batch,
         hours_into_batch, value, deviation_pct) %>%
  arrange(measure, batch, position_in_batch)
write_csv(outlier_runs, file.path(OUT, "tables", "rw_outlier_runs.csv"))

# Where in the batches do the energy outliers occur? Under no time effect, about 10% of
# them would fall in the first 10% of a batch.
energy_outlier_timing <- outlier_runs %>%
  filter(measure == "E") %>%
  left_join(count(dat, batch, name = "runs_in_batch"), by = "batch") %>%
  summarise(energy_outliers = n(),
            in_first_10pct_of_batch = sum(position_in_batch <= 0.1 * runs_in_batch, na.rm = TRUE),
            per_batch = paste(table(factor(batch, levels = sort(unique(dat$batch)))), collapse = " / "))
cat("\nEnergy outliers: total, in the first 10% of their batch, per batch (1 / 2 / 3):\n")
print(energy_outlier_timing)

# ---- 3. descriptive statistics ----------------------------------------------
describe <- function(x) c(mean = mean(x), median = median(x), sd = sd(x), iqr = IQR(x),
                          min = min(x), max = max(x), cv = sd(x) / mean(x))

descriptives <- long %>%
  group_by(measure, operation, payload, library) %>%
  summarise(n = n(), as_tibble_row(describe(value)), .groups = "drop")
write_csv(descriptives, file.path(OUT, "tables", "rw_desc_all.csv"))
for (m in names(MEASURES)) {
  save_table(descriptives %>% filter(measure == m) %>% select(-measure),
             paste0("rw_desc_", m), paste("Descriptive statistics of", MEASURES[m], "- real-world block"),
             if (m == "CPU") 3 else 2)
}

# ---- 4. exploration plots ---------------------------------------------------
# Figures are saved at their printed size in the two-column ACM layout (full width = 7 in,
# one column = 3.33 in), so the fonts appear at their real size and need no scaling in LaTeX.
FULL_W <- 7; COL_W <- 3.33
# Strip labels name only the operation and payload; the library is shown by the colour
# (legend on top), which keeps the labels short enough for the narrow panels.
op_payload_labeller <- function(labels) list(paste(labels$operation, labels$payload))
theme_set(theme_bw(base_size = 8) + theme(plot.margin = margin(2, 4, 2, 2)))
lib_colours <- c(json = "#1b9e77", orjson = "#d95f02")
op_labels <- c(dumps = "Serialisation (dumps)", loads = "Deserialisation (loads)")

for (m in names(MEASURES)) {
  p <- ggplot(filter(long, measure == m), aes(x = library, y = value, fill = library)) +
    geom_violin(alpha = 0.5, scale = "width", trim = FALSE) +
    geom_boxplot(width = 0.15, outlier.size = 0.8, fill = "white") +
    facet_wrap(~ operation + payload, scales = "free_y", nrow = 2,
               labeller = labeller(operation = op_labels)) +
    scale_fill_manual(values = lib_colours, guide = "none") +
    labs(x = "Library", y = MEASURES[m])
  ggsave(file.path(OUT, "figures", paste0("rw_violin_", m, ".pdf")), p, width = FULL_W, height = 3)
}

# Box plots, one panel per configuration AND library with its own y axis: the runs of one
# configuration vary by about 1%, while the libraries differ by 2-20x, so on a shared axis
# the boxes collapse into lines. Whiskers end at 1.5 x IQR, the outlier rule of Section 4.5,
# so every point drawn beyond them is a flagged run.
for (m in names(MEASURES)) {
  p <- ggplot(filter(long, measure == m), aes(x = library, y = value, fill = library)) +
    geom_boxplot(width = 0.5, outlier.colour = "red", outlier.size = 1.2, alpha = 0.6, coef = 1.5) +
    facet_wrap(~ operation + payload + library, scales = "free", nrow = 2,
               labeller = op_payload_labeller) +
    scale_fill_manual(values = lib_colours, name = "Library") +
    labs(x = NULL, y = MEASURES[m]) +
    theme(axis.text.x = element_blank(), axis.ticks.x = element_blank(),
          legend.position = "top", legend.margin = margin(0, 0, 0, 0),
          legend.box.margin = margin(0, 0, -6, 0), legend.key.size = unit(8, "pt"),
          axis.text.y = element_text(size = 5.5), strip.text = element_text(size = 5.5),
          panel.spacing = unit(2, "pt"))
  ggsave(file.path(OUT, "figures", paste0("rw_boxplot_", m, ".pdf")), p, width = FULL_W, height = 2.4)
}

# Energy over the course of each batch: deviation of every run from its configuration's
# median, against the time the run started. Clusters of outliers (e.g. at the start of a
# batch, or in one batch only) point to a disturbance; random scatter points to noise.
p_time <- outliers %>%
  filter(measure == "E") %>%
  group_by(operation, payload, library) %>%
  mutate(deviation_pct = 100 * (value / median(value) - 1)) %>%
  ungroup() %>%
  filter(!is.na(hours_into_batch)) %>%
  ggplot(aes(x = hours_into_batch, y = deviation_pct, colour = outlier, shape = library)) +
  geom_hline(yintercept = 0, colour = "grey60") +
  geom_point(size = 1.3, alpha = 0.8) +
  facet_wrap(~ batch, nrow = 1, labeller = labeller(batch = function(b) paste("Batch", b))) +
  scale_colour_manual(values = c(`FALSE` = "grey40", `TRUE` = "red"),
                      labels = c(`FALSE` = "regular run", `TRUE` = "outlier (1.5 x IQR)")) +
  labs(x = "Hours since the start of the batch", y = "Energy deviation from\nconfiguration median (%)",
       colour = NULL, shape = "Library") +
  theme(legend.position = "bottom", legend.box = "vertical", legend.margin = margin(0, 0, 0, 0),
        legend.spacing.y = unit(0, "pt"), axis.title.y = element_text(size = 7))
ggsave(file.path(OUT, "figures", "rw_energy_over_time.pdf"), p_time, width = COL_W, height = 2.8)

# Scatter plots E vs each performance measure (RQ2.1-RQ2.3), one panel per configuration
for (x in names(PERF)) {
  p <- ggplot(dat, aes(x = .data[[x]], y = E, colour = library)) +
    geom_point(size = 1, alpha = 0.7) +
    geom_smooth(method = "lm", formula = y ~ x, se = FALSE, linewidth = 0.5) +
    facet_wrap(~ operation + payload + library, scales = "free", nrow = 2,
               labeller = op_payload_labeller) +
    scale_colour_manual(values = lib_colours, name = "Library") +
    scale_x_continuous(breaks = scales::breaks_extended(n = 3), guide = guide_axis(check.overlap = TRUE)) +
    labs(x = MEASURES[x], y = MEASURES["E"]) +   # the figure caption carries the title
    theme(legend.position = "top", legend.margin = margin(0, 0, 0, 0),
          legend.box.margin = margin(0, 0, -6, 0), legend.key.size = unit(8, "pt"),
          axis.text = element_text(size = 4.5), strip.text = element_text(size = 5.5),
          panel.spacing = unit(2, "pt"))
  ggsave(file.path(OUT, "figures", paste0("rq2_scatter_E_", x, ".pdf")), p, width = FULL_W, height = 2.6)
}

# ---- 5. normality and homogeneity of variance --------------------------------
shapiro_p <- function(x) {
  if (length(unique(x)) < 3) return(NA_real_)   # constant data: not testable, treated as non-normal
  tryCatch(shapiro.test(x)$p.value, error = function(e) NA_real_)
}
is_normal <- function(x) { p <- shapiro_p(x); !is.na(p) && p > ALPHA }

normality <- long %>%
  group_by(measure, operation, payload, library) %>%
  summarise(shapiro_p_raw = shapiro_p(value),
            shapiro_p_log = if (all(value > 0)) shapiro_p(log(value)) else NA_real_,
            .groups = "drop") %>%
  mutate(normal_raw = !is.na(shapiro_p_raw) & shapiro_p_raw > ALPHA,
         normal_log = !is.na(shapiro_p_log) & shapiro_p_log > ALPHA)
save_table(normality, "rw_normality", "Shapiro-Wilk p-values per configuration, real-world block (raw and log-transformed)", 4)
cat("\nShare of normal samples (raw / after log):",
    round(mean(normality$normal_raw), 2), "/", round(mean(normality$normal_raw | normality$normal_log), 2), "\n")

# Brown-Forsythe version of Levene's test (median-centred), json vs orjson per payload
levene_p <- function(y, g) {
  dev <- abs(y - ave(y, g, FUN = median))
  anova(lm(dev ~ g))[["Pr(>F)"]][1]
}
homogeneity <- long %>%
  group_by(measure, operation, payload) %>%
  summarise(levene_p = levene_p(value, library), .groups = "drop")
write_csv(homogeneity, file.path(OUT, "tables", "rw_levene.csv"))

pdf(file.path(OUT, "figures", "rw_qqplots_E.pdf"), width = 12, height = 6)
par(mfrow = c(2, 8), mar = c(3, 3, 2, 1))
for (g in split(dat, list(dat$library, dat$payload, dat$operation), drop = TRUE)) {
  qqnorm(g$E, main = paste(g$operation[1], g$payload[1], g$library[1]), cex.main = 0.8)
  qqline(g$E)
}
invisible(dev.off())

# Scale used for a test (Section 4.5): raw data if every sample is normal, otherwise
# the log-transformed data if that makes every sample normal, otherwise ranks
# (non-parametric test).
choose_scale <- function(samples) {
  if (all(map_lgl(samples, is_normal))) return("raw")
  if (all(map_lgl(samples, ~ all(.x > 0))) && all(map_lgl(samples, ~ is_normal(log(.x))))) return("log")
  "rank"
}
apply_scale <- function(x, scale) if (scale == "log") log(x) else x

# ---- 6. RQ2.1-RQ2.3: correlations ---------------------------------------------
safe_cor_test <- function(x, y, method) {
  if (sd(x) == 0 || sd(y) == 0) return(list(estimate = NA_real_, p.value = NA_real_))
  r <- suppressWarnings(cor.test(x, y, method = method, exact = FALSE))
  list(estimate = unname(r$estimate), p.value = r$p.value)
}
fisher_z_p <- function(r1, n1, r2, n2) {
  z <- (atanh(r1) - atanh(r2)) / sqrt(1 / (n1 - 3) + 1 / (n2 - 3))
  2 * pnorm(-abs(z))
}
boot_spearman_diff <- function(e1, x1, e2, x2, B = N_BOOT) {
  rho <- function(e, x) suppressWarnings(cor(e, x, method = "spearman"))
  d <- replicate(B, {
    i <- sample.int(length(e1), replace = TRUE); j <- sample.int(length(e2), replace = TRUE)
    rho(e1[i], x1[i]) - rho(e2[j], x2[j])
  })
  d <- d[!is.na(d)]
  if (length(d) < 100) return(list(lo = NA_real_, hi = NA_real_, p = NA_real_))
  list(lo = unname(quantile(d, 0.025)), hi = unname(quantile(d, 0.975)),
       p = min(1, 2 * min(mean(d <= 0), mean(d >= 0))))   # two-sided bootstrap p-value
}

set.seed(SEED)
corr_rows <- list(); diff_rows <- list()
for (op in levels(dat$operation)) for (pl in levels(dat$payload)) for (x in names(PERF)) {
  d <- dat %>% filter(operation == op, payload == pl)
  j <- d %>% filter(library == "json"); o <- d %>% filter(library == "orjson")
  scale <- choose_scale(list(j$E, j[[x]], o$E, o[[x]]))
  method <- if (scale == "rank") "spearman" else "pearson"

  for (lib in c("json", "orjson")) {
    s <- if (lib == "json") j else o
    ct <- safe_cor_test(apply_scale(s$E, scale), apply_scale(s[[x]], scale), method)
    corr_rows[[length(corr_rows) + 1]] <- tibble(
      rq = PERF[[x]], operation = op, payload = pl, X = x, library = lib, n = nrow(s),
      scale = scale, method = method, r = ct$estimate, p = ct$p.value)
  }
  rj <- tail(corr_rows, 2)[[1]]$r; ro <- tail(corr_rows, 2)[[2]]$r
  if (method == "pearson") {
    pd <- if (is.na(rj) || is.na(ro)) NA_real_ else fisher_z_p(rj, nrow(j), ro, nrow(o))
    bd <- list(lo = NA_real_, hi = NA_real_)
    test <- "Fisher z-test"
  } else {
    bd <- boot_spearman_diff(j$E, j[[x]], o$E, o[[x]]); pd <- bd$p
    test <- "bootstrap (Spearman)"
  }
  diff_rows[[length(diff_rows) + 1]] <- tibble(
    rq = PERF[[x]], operation = op, payload = pl, X = x, test = test,
    r_json = rj, r_orjson = ro, diff = rj - ro, ci_low = bd$lo, ci_high = bd$hi, p = pd)
}
corr_res <- bind_rows(corr_rows)
diff_res <- bind_rows(diff_rows)

# ---- 7. supporting comparisons H0^S(p, M) -----------------------------------
cliffs_delta <- function(x, y) mean(sign(outer(x, y, "-")))
cohens_d <- function(x, y) (mean(x) - mean(y)) / sqrt(((length(x) - 1) * var(x) + (length(y) - 1) * var(y)) /
                                                       (length(x) + length(y) - 2))
cliff_magnitude <- function(d) as.character(cut(abs(d), c(-Inf, 0.147, 0.33, 0.474, Inf),
                                                labels = c("negligible", "small", "medium", "large")))

supp_rows <- list()
for (op in levels(dat$operation)) for (pl in levels(dat$payload)) for (m in names(MEASURES)) {
  d <- dat %>% filter(operation == op, payload == pl)
  x <- d[[m]][d$library == "json"]; y <- d[[m]][d$library == "orjson"]
  scale <- choose_scale(list(x, y))
  if (scale == "rank") {
    p <- suppressWarnings(wilcox.test(x, y, exact = FALSE))$p.value; test <- "Mann-Whitney U"
  } else {
    p <- t.test(apply_scale(x, scale), apply_scale(y, scale), var.equal = FALSE)$p.value
    test <- if (scale == "log") "Welch t-test (log)" else "Welch t-test"
  }
  cd <- cliffs_delta(x, y)
  supp_rows[[length(supp_rows) + 1]] <- tibble(
    operation = op, payload = pl, measure = m, test = test,
    median_json = median(x), median_orjson = median(y),
    rel_diff_pct = 100 * (median(y) - median(x)) / median(x),   # orjson vs json
    p = p, cliffs_delta = cd, cliff_magnitude = cliff_magnitude(cd), cohens_d = cohens_d(x, y))
}
supp_res <- bind_rows(supp_rows)

# ---- 8. Benjamini-Hochberg over all tests of the real-world block -----------
all_p <- c(corr_res$p, diff_res$p, supp_res$p)
all_adj <- p.adjust(all_p, method = "BH")      # NA p-values (untestable) stay NA
n1 <- nrow(corr_res); n2 <- nrow(diff_res)
corr_res$p_adj <- all_adj[seq_len(n1)]
diff_res$p_adj <- all_adj[n1 + seq_len(n2)]
supp_res$p_adj <- all_adj[n1 + n2 + seq_len(nrow(supp_res))]
for (nm in c("corr_res", "diff_res", "supp_res")) {
  t <- get(nm); t$significant <- !is.na(t$p_adj) & t$p_adj < ALPHA; assign(nm, t)
}

cat("\nH0^2.s - correlation between energy and X, per library x operation x payload:\n")
print(corr_res, n = Inf, width = Inf)
cat("\nH0^2.s,Delta - does the correlation differ between json and orjson?\n")
print(diff_res, n = Inf, width = Inf)
cat("\nH0^S(p, M) - json vs orjson per payload:\n")
print(supp_res, n = Inf, width = Inf)

save_table(corr_res, "rq2_correlations",
           "RQ2.1--RQ2.3: correlation between energy and each performance measure per configuration (BH-adjusted p-values)", 4)
save_table(diff_res, "rq2_corr_diff",
           "RQ2.1--RQ2.3: difference between the correlations of json and orjson (BH-adjusted p-values)", 4)
save_table(supp_res, "rq2_supporting",
           "Supporting comparisons: json vs orjson on every real-world payload (BH-adjusted p-values)", 4)

# Compact overview for the report: one row per RQ x operation, how many of the 4
# payloads show a significant correlation for each library, and the range of r.
summary_res <- corr_res %>%
  group_by(rq, X, operation, library) %>%
  summarise(significant_payloads = sum(significant), r_min = min(r, na.rm = TRUE),
            r_max = max(r, na.rm = TRUE), .groups = "drop")
save_table(summary_res, "rq2_summary", "RQ2 overview: significant correlations out of 4 payloads and range of the coefficients", 2)
cat("\nRQ2 overview:\n"); print(summary_res, n = Inf)

cat("\nDone. Figures in", file.path(OUT, "figures"), "- tables in", file.path(OUT, "tables"), "\n")
