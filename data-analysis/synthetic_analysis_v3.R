# =============================================================================
# Data analysis - json vs orjson (Green Lab 2026/2027)
#
# Synthetic block: RQ1 (library effect on energy) and RQ1.1 (library x payload
# complexity interaction on energy efficiency, J/KB).
#
# MODULAR USAGE (Positron / RStudio): source this file, then call the stages
# you need. Nothing runs on source() when the session is interactive.
#
#   source("data-analysis/synthetic_analysis_v.R")
#   dat         <- clean_data()            # stage 1: load, clean, flag outliers (saves CSV)
#   dat         <- load_clean()            # ...or reload the saved CSV later, skipping stage 1
#   describe_data(dat)                     # stage 2: descriptive statistics tables
#   plot_distributions(dat)                # stage 3: violin + per-library box plots (E and EE)
#   plot_qq_efficency(dat)                 #          Q-Q plots for mJ/KB
#   plot_qq_energy(dat)                    #          Q-Q plots for J
#   # Run RQ1 and RQ1.1 independently (separate response variables and output files)
#   assump_E <- check_assumptions(dat, response = "energy_J",
#                                 file_prefix = "RQ1_energy")
#   approach_E <- choose_approach(assump_E)
#   res_rq1 <- test_rq1(dat, approach_E, response = "energy_J")
#   sensitivity_check(dat, res_rq1, approach_E, response = "energy_J")
#
#   assump_EE <- check_assumptions(dat, response = "efficiency_J_per_KB",
#                                  file_prefix = "RQ1_1_efficiency")
#   approach_EE <- choose_approach(assump_EE)
#   res_rq1_1 <- test_rq1(dat, approach_EE, response = "efficiency_J_per_KB")
#   sensitivity_check(dat, res_rq1_1, approach_EE,
#                     response = "efficiency_J_per_KB")
#   plot_interaction(dat)                  # interaction plot for RQ1.1
#
# Or run everything at once from the repository root:
#   Rscript data-analysis/synthetic_analysis_v3.R
#
# Outputs:
#   data-analysis/figures/synthetic_v3/*.pdf
#   data-analysis/tables/synthetic_v3/*.csv and *.tex
#   data-analysis/processed/synthetic_v3/synthetic_clean.csv
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
ALPHA         <- 0.05
INPUT         <- "results/synthetic_all.csv"
RESULTS_DIRS <- c(
  "results/json_energy_synthetic_batch1of3",
  "results/json_energy_synthetic_batch2of3",
  "results/json_energy_synthetic_batch3of3"
)
OUT           <- "data-analysis"
VERSION       <- "synthetic_v3"

FIG_DIR    <- file.path(OUT, "figures", VERSION)
TAB_DIR    <- file.path(OUT, "tables", VERSION)
PROC_DIR   <- file.path(OUT, "processed", VERSION)
CLEAN_FILE <- file.path(PROC_DIR, "synthetic_clean.csv")

# Transformations tried (in this order) before falling back to non-parametric tests
TRANSFORMS <- list(none = identity, log = log, sqrt = sqrt)

# Figures are saved at their printed size in the two-column ACM layout
# (full width = 7 in, one column = 3.33 in), so fonts appear at their real size.
FULL_W <- 7; COL_W <- 3.33
theme_set(theme_bw(base_size = 8) + theme(plot.margin = margin(2, 4, 2, 2)))
lib_colours <- c(json = "#1b9e77", orjson = "#d95f02")
op_labels <- labeller(operation = c(dumps = "Serialisation (dumps)", loads = "Deserialisation (loads)"),
                      payload = c(simple = "Simple", moderate = "Moderate", complex = "Complex"))
op_payload_labeller <- function(labels) list(paste(labels$operation, labels$payload))

# ---- helper functions -------------------------------------------------------
setup_dirs <- function() {
  for (d in c(FIG_DIR, TAB_DIR, PROC_DIR)) dir.create(d, showWarnings = FALSE, recursive = TRUE)
}

save_table <- function(df, name, caption, digits = 3) {
  setup_dirs()
  write_csv(df, file.path(TAB_DIR, paste0(name, ".csv")))
  print(xtable(df, caption = caption, label = paste0("tab:", name), digits = digits),
        file = file.path(TAB_DIR, paste0(name, ".tex")),
        include.rownames = FALSE, booktabs = TRUE)
}

save_fig <- function(p, name, width, height) {
  setup_dirs()
  ggsave(file.path(FIG_DIR, name), p, width = width, height = height)
}

set_factors <- function(dat) {
  dat %>% mutate(
    library   = factor(library,   levels = c("json", "orjson")),
    operation = factor(operation, levels = c("dumps", "loads")),
    payload   = factor(payload,   levels = c("simple", "moderate", "complex"))
  )
}

# 1.5 x IQR rule
iqr_flag <- function(x) {
  q <- quantile(x, c(0.25, 0.75)); i <- q[2] - q[1]
  x < q[1] - 1.5 * i | x > q[2] + 1.5 * i
}

# Shapiro-Wilk that does not crash on (near-)constant data: such samples count as not normal
safe_shapiro_p <- function(x) {
  if (length(unique(x)) < 3) return(NA_real_)
  tryCatch(shapiro.test(x)$p.value, error = function(e) NA_real_)
}

# Brown-Forsythe version of Levene's test (same as car::leveneTest, center = median)
levene_test_p <- function(y, g) {
  dev <- abs(y - ave(y, g, FUN = median))
  anova(lm(dev ~ g))[["Pr(>F)"]][1]
}

# Effect sizes
cliffs_delta <- function(x, y) mean(sign(outer(x, y, "-")))
cohens_d <- function(x, y) {
  (mean(x) - mean(y)) / sqrt(((length(x) - 1) * var(x) + (length(y) - 1) * var(y)) /
                               (length(x) + length(y) - 2))
}
cliff_magnitude <- function(d) {
  as.character(cut(abs(d), c(-Inf, 0.147, 0.33, 0.474, Inf),
                   labels = c("negligible", "small", "medium", "large")))
}

# Volume processed in each run: taken from the CSV if it has a volume_bytes column,
# otherwise read from each run's benchmark.json in RESULTS_DIR.
get_volume_bytes <- function(run_table) {
  volume <- if ("volume_bytes" %in% names(run_table)) {
    suppressWarnings(as.numeric(run_table$volume_bytes))
  } else {
    rep(NA_real_, nrow(run_table))
  }

  # Index all benchmark files in the three batch directories
  files <- unlist(lapply(
    RESULTS_DIRS,
    list.files,
    pattern = "benchmark\\.json$",
    recursive = TRUE,
    full.names = TRUE
  ))

  # Match files to run IDs
  for (i in which(is.na(volume))) {
    run_id <- as.character(run_table$`__run_id`[i])
    matches <- files[
      grepl(run_id, basename(dirname(files)), fixed = TRUE)
    ]

    if (length(matches) == 0) {
      message("No benchmark.json found for: ", run_id)
      next
    }

    benchmark <- tryCatch(
      jsonlite::fromJSON(matches[1]),
      error = function(e) NULL
    )

    if (!is.null(benchmark$volume_bytes)) {
      volume[i] <- as.numeric(benchmark$volume_bytes)
    }
  }

  volume
}

# =============================================================================
# STAGE 1: load and clean
# =============================================================================
clean_data <- function(save = TRUE) {
  setup_dirs()

  if (!file.exists(INPUT)) {
    stop("Run from the repository root (", INPUT, " not found).")
  }

  run_table <- read_csv(INPUT, show_col_types = FALSE)

  cat("Runs in run table:", nrow(run_table), "\n")
  cat(
    "Runs not DONE (to re-execute):",
    sum(run_table$`__done` != "DONE", na.rm = TRUE), "\n"
  )

  dat <- run_table %>%
    filter(`__done` == "DONE") %>%
    mutate(
      across(
        any_of(c(
          "execution_time_s",
          "cpu_utilisation_pct",
          "peak_memory_bytes",
          "energy_J",
          "idle_power_W"
        )),
        as.numeric
      )
    )

  # Retrieve volume_bytes from the CSV or the batch benchmark.json files.
  dat$volume_bytes <- get_volume_bytes(dat)

  dat <- dat %>%
    mutate(
      volume_bytes = as.numeric(volume_bytes),
      energy_raw_J = energy_J,
      energy_J = if (SUBTRACT_IDLE) {
        energy_J - idle_power_W * execution_time_s
      } else {
        energy_J
      },
      volume_KB = volume_bytes / 1000,
      efficiency_J_per_KB = energy_J / volume_KB,
      efficiency_uJ_per_KB = efficiency_J_per_KB * 1e6,
      power_W = energy_J / execution_time_s
    ) %>%
    set_factors()

  # Anomaly check
  anomalies <- dat %>%
    summarise(
      missing_volume = sum(is.na(volume_bytes)),
      non_positive_energy = sum(energy_J <= 0, na.rm = TRUE),
      non_positive_time = sum(execution_time_s <= 0, na.rm = TRUE)
    )

  cat("\nAnomaly check:\n")
  print(anomalies)

  if (anomalies$missing_volume > 0) {
    warning("Some runs have no volume: efficiency is NA for them.")
  }

  # Flag outliers using energy OR execution time; retain them in the analysis.
  dat <- dat %>%
    group_by(operation, payload, library) %>%
    mutate(
      outlier_energy = iqr_flag(energy_J),
      outlier_time = iqr_flag(execution_time_s),
      outlier_any = outlier_energy | outlier_time
    ) %>%
    ungroup()

  cat(
    "\nFlagged outliers: energy =", sum(dat$outlier_energy, na.rm = TRUE),
    "| energy or time =", sum(dat$outlier_any, na.rm = TRUE), "\n"
  )

  print(
    dat %>%
      filter(outlier_any) %>%
      count(operation, payload, library)
  )

  if (save) {
    write_csv(dat, CLEAN_FILE)
    cat("\nCleaned data saved to:", CLEAN_FILE, "\n")
  }

  dat
}


# ---- Reload cleaned data ----------------------------------------------------
load_clean <- function() {
  if (!file.exists(CLEAN_FILE)) {
    stop("No cleaned data found; run clean_data() first.")
  }

  read_csv(CLEAN_FILE, show_col_types = FALSE) %>%
    set_factors()
}
# =============================================================================
# STAGE 2: descriptive statistics (mean, median, SD, IQR of E and EE)
# =============================================================================
describe_data <- function(dat, save = TRUE) {
  desc <- dat %>%
    pivot_longer(c(energy_J, efficiency_uJ_per_KB), names_to = "measure", values_to = "value") %>%
    group_by(measure, operation, payload, library) %>%
    summarise(n = n(), mean = mean(value), median = median(value),
              sd = sd(value), iqr = IQR(value), cv = sd(value) / mean(value),
              .groups = "drop")
  if (save) {
    save_table(desc %>% filter(measure == "energy_J") %>% select(-measure),
               "desc_energy", "Descriptive statistics of energy consumption (J), synthetic block", 1)
    save_table(desc %>% filter(measure == "efficiency_uJ_per_KB") %>% select(-measure),
               "desc_efficiency",
               "Descriptive statistics of energy efficiency ($\\mu$J/KB), synthetic block", 2)
  }
  print(desc, n = Inf, width = Inf)
  invisible(desc)
}

# =============================================================================
# STAGE 3: plots for exploration
# =============================================================================
# Violin: one panel per operation x payload with its own y scale.
violin_plot <- function(dat, y, y_label) {
  ggplot(dat, aes(x = library, y = .data[[y]], fill = library)) +
    geom_violin(alpha = 0.5, scale = "width", trim = FALSE) +
    geom_boxplot(width = 0.15, outlier.size = 0.8, fill = "white") +
    facet_wrap(~ operation + payload, scales = "free_y", nrow = 2, labeller = op_labels) +
    scale_fill_manual(values = lib_colours, guide = "none") +
    labs(x = "Library", y = y_label)
}

# Box plots with one panel per operation x payload x LIBRARY and its own axes: runs within
# a configuration vary by about 1% while the libraries differ by several times, so on a
# shared axis the boxes collapse into lines. Whiskers end at 1.5 x IQR (the outlier rule),
# so every red point is a flagged run.
box_plot <- function(dat, y, y_label) {
  ggplot(dat, aes(x = library, y = .data[[y]], fill = library)) +
    geom_boxplot(width = 0.5, coef = 1.5, alpha = 0.6,
                 outlier.colour = "red", outlier.size = 1.2) +
    facet_wrap(~ operation + payload + library, scales = "free", nrow = 2,
               labeller = op_payload_labeller) +
    scale_fill_manual(values = lib_colours, name = "Library") +
    labs(x = NULL, y = y_label) +
    theme(axis.text.x = element_blank(), axis.ticks.x = element_blank(),
          legend.position = "top", legend.margin = margin(0, 0, 0, 0),
          legend.box.margin = margin(0, 0, -6, 0), legend.key.size = unit(8, "pt"),
          axis.text.y = element_text(size = 5.5), strip.text = element_text(size = 5.5),
          panel.spacing = unit(2, "pt"))
}

plot_distributions <- function(dat, save = TRUE) {
  eff_lab <- expression("Energy efficiency (" * mu * "J/KB)")
  plots <- list(
    violin_efficiency = violin_plot(dat, "efficiency_uJ_per_KB", eff_lab),
    violin_energy     = violin_plot(dat, "energy_J", "Energy consumption (J)"),
    box_efficiency    = box_plot(dat, "efficiency_uJ_per_KB", eff_lab),
    box_energy        = box_plot(dat, "energy_J", "Energy consumption (J)")
  )
  if (save) {
    save_fig(plots$violin_efficiency, "violin_efficiency.pdf", FULL_W, 3.6)
    save_fig(plots$violin_energy,     "violin_energy.pdf",     FULL_W, 3.6)
    save_fig(plots$box_efficiency,    "box_efficiency.pdf",    FULL_W, 2.4)
    save_fig(plots$box_energy,        "box_energy.pdf",        FULL_W, 2.4)
  }
  invisible(plots)
}

plot_qq_efficency <- function(dat, response = "efficiency_J_per_KB", save = TRUE) {
  draw <- function() {
    par(mfrow = c(2, 6), mar = c(3, 3, 2, 1))

    for (g in split(dat, list(dat$library, dat$payload, dat$operation), drop = TRUE)) {
      # Convert from microjoules/KB to millijoules/KB
      efficiency_mJ_per_KB <- g[[response]] / 1000

      qqnorm(
        efficiency_mJ_per_KB,
        main = paste(g$operation[1], g$payload[1], g$library[1]),
        cex.main = 0.8,
        ylab = "Theoretical Quantiles",
        xlab = "Sample Quantiles (mJ/KB)"
      )
      qqline(efficiency_mJ_per_KB)
    }
  }

  if (save) {
    setup_dirs()
    pdf(file.path(FIG_DIR, "qqplots_efficiency_mJ_per_KB.pdf"),
        width = 9, height = 6)
    draw()
    invisible(dev.off())
  } else {
    draw()
  }
}

plot_qq_energy <- function(dat, response = "energy_J", save = TRUE) {
  draw <- function() {
    par(mfrow = c(2, 6), mar = c(3, 3, 2, 1))
    for (g in split(dat, list(dat$library, dat$payload, dat$operation), drop = TRUE)) {
      qqnorm(
        g[[response]],
        main = paste(g$operation[1], g$payload[1], g$library[1]),
        cex.main = 0.8
      )
      qqline(g[[response]])
    }
  }

  if (save) {
    setup_dirs()
    pdf(file.path(FIG_DIR, "qqplots_energy.pdf"), width = 9, height = 6)
    draw()
    invisible(dev.off())
  } else {
    draw()
  }
}

# =============================================================================
# STAGE 4: assumptions -> decide parametric vs non-parametric
# =============================================================================
# Shapiro-Wilk per configuration and Levene per operation, on the raw, log and
# sqrt scale (the plan: try a transformation first, then go non-parametric).
check_assumptions <- function(
    dat,
    response = "efficiency_J_per_KB",
    save = TRUE,
    file_prefix = if (response == "energy_J") "RQ1_energy" else "RQ1_1_efficiency"
) {
  normality <- map_dfr(names(TRANSFORMS), function(tr) {
    dat %>%
      group_by(operation, payload, library) %>%
      summarise(shapiro_p = safe_shapiro_p(TRANSFORMS[[tr]](.data[[response]])), .groups = "drop") %>%
      mutate(transform = tr)
  }) %>% mutate(normal = !is.na(shapiro_p) & shapiro_p > ALPHA)

  levene <- map_dfr(names(TRANSFORMS), function(tr) {
    dat %>%
      group_by(operation) %>%
      summarise(levene_p = levene_test_p(TRANSFORMS[[tr]](.data[[response]]),
                                         interaction(library, payload)), .groups = "drop") %>%
      mutate(transform = tr)
  }) %>% mutate(equal_var = levene_p > ALPHA)

  summary <- normality %>%
    group_by(operation, transform) %>%
    summarise(n_normal = sum(normal), n_cells = n(), all_normal = all(normal), .groups = "drop") %>%
    left_join(levene, by = c("operation", "transform")) %>%
    mutate(parametric_ok = all_normal & equal_var)

  if (save) {
    save_table(
      normality,
      paste0("normality_", file_prefix),
      paste("Shapiro-Wilk p-values per configuration for", response,
            "(raw, log and sqrt)"),
      4
    )
    save_table(
      summary,
      paste0("assumptions_summary_", file_prefix),
      paste("Normality (Shapiro-Wilk) and homogeneity of variance (Levene)",
            "per operation and transformation for", response),
      4
    )
  }
  cat("\nAssumption summary (parametric_ok = all cells normal AND equal variances):\n")
  print(summary, width = Inf)
  share <- function(tr) round(mean(normality$normal[normality$transform == tr]), 2)
  cat("\nShare of samples passing Shapiro-Wilk: raw", share("none"),
      "| log", share("log"), "| sqrt", share("sqrt"), "\n")
  invisible(list(normality = normality, levene = levene, summary = summary))
}

# Picks, per operation, the first transformation (none, log, sqrt) that satisfies
# both assumptions; otherwise non-parametric. You can overwrite this table by hand,
# e.g. approach$parametric <- FALSE, before calling test_rq1().
choose_approach <- function(assumptions) {
  approach <- assumptions$summary %>%
    mutate(order = match(transform, names(TRANSFORMS))) %>%
    group_by(operation) %>%
    arrange(order, .by_group = TRUE) %>%
    summarise(parametric = any(parametric_ok),
              transform = if (any(parametric_ok)) transform[which(parametric_ok)[1]] else "none",
              .groups = "drop")
  cat("\nChosen approach:\n"); print(approach)
  approach
}

# =============================================================================
# STAGE 5: hypothesis tests (only what the plan needs)
#   RQ1   H0^1   : effect of library        (term "library")
#   RQ1.1 H0^1.1 : library x complexity     (term "library:payload")
#   H0^1(c)      : json vs orjson per complexity level, only if the interaction
#                  is significant (or posthoc_always = TRUE)
# All tests of the block are corrected jointly with Benjamini-Hochberg.
# =============================================================================
test_rq1 <- function(
    dat,
    approach = NULL,
    response = "energy_J",
    posthoc_always = FALSE,
    save = TRUE
) {
  if (response == "energy_J") {
    analysis_name <- "RQ1_energy"
    response_label <- "energy consumption (J)"
  } else if (response %in% c("efficiency_J_per_KB", "efficiency_uJ_per_KB")) {
    analysis_name <- "RQ1_1_efficiency"
    response_label <- "energy efficiency"
  } else {
    analysis_name <- paste0("analysis_", response)
    response_label <- response
  }

  if (is.null(approach)) {
    assumptions <- check_assumptions(
      dat, response = response, save = save, file_prefix = analysis_name
    )
    approach <- choose_approach(assumptions)
  }

  anova_rows <- list()
  pairwise_rows <- list()

  for (op in levels(dat$operation)) {
    row <- approach[approach$operation == op, ]
    if (nrow(row) != 1) {
      stop("Expected exactly one approach row for operation: ", op)
    }

    tf <- TRANSFORMS[[row$transform]]
    d <- dat %>%
      filter(operation == op) %>%
      mutate(y = tf(.data[[response]]))

    if (row$parametric) {
      fit <- lm(y ~ library * payload, data = d)
      a <- as.data.frame(anova(fit))
      a <- a[rownames(a) != "Residuals", ]
      terms <- rownames(a)
      f <- a[["F value"]]
      df1 <- a[["Df"]]
      df2 <- df.residual(fit)
      p <- a[["Pr(>F)"]]
      test_name <- "two-way ANOVA"
    } else {
      # ART performs alignment/ranking internally. Use the original response
      # for ART instead of applying a pre-transformation.
      art_fit <- art(y ~ library * payload, data = d)
      a <- as.data.frame(anova(art_fit))
      terms <- if ("Term" %in% names(a)) as.character(a$Term) else rownames(a)
      f <- a[[grep("^F", names(a))[1]]]
      df1 <- a[["Df"]]
      df2 <- a[["Df.res"]]
      p <- a[[grep("^Pr", names(a))[1]]]
      test_name <- "ART ANOVA"
    }

    keep <- terms %in% c("library", "library:payload")
    res_op <- tibble(
      analysis = analysis_name,
      response = response,
      operation = op,
      test = test_name,
      transform = row$transform,
      term = terms,
      F = f,
      df1 = df1,
      df2 = df2,
      p = p,
      partial_eta2 = (f * df1) / (f * df1 + df2)
    )[keep, ]

    res_op$effect_tested <- ifelse(
      res_op$term == "library",
      "Library main effect",
      "Library x payload interaction"
    )
    anova_rows[[op]] <- res_op

    interaction_p <- res_op$p[res_op$term == "library:payload"]
    if (posthoc_always ||
        (length(interaction_p) == 1 && !is.na(interaction_p) &&
         interaction_p < ALPHA)) {
      for (pl in levels(d$payload)) {
        xs <- d$y[d$library == "json" & d$payload == pl]
        ys <- d$y[d$library == "orjson" & d$payload == pl]
        xr <- d[[response]][d$library == "json" & d$payload == pl]
        yr <- d[[response]][d$library == "orjson" & d$payload == pl]

        if (row$parametric) {
          tst <- t.test(xs, ys, var.equal = FALSE)
          tname <- "Welch t-test"
          eff <- cohens_d(xs, ys)
          eff_type <- "Cohen's d"
          mag <- NA_character_
        } else {
          tst <- wilcox.test(xs, ys, exact = FALSE)
          tname <- "Mann-Whitney U"
          eff <- cliffs_delta(xs, ys)
          eff_type <- "Cliff's delta"
          mag <- cliff_magnitude(eff)
        }

        pairwise_rows[[paste(op, pl)]] <- tibble(
          analysis = analysis_name,
          response = response,
          operation = op,
          payload = pl,
          test = tname,
          median_json = median(xr),
          median_orjson = median(yr),
          rel_diff_pct = 100 * (median(yr) - median(xr)) / median(xr),
          ratio_json_over_orjson = median(xr) / median(yr),
          p = tst$p.value,
          effect_type = eff_type,
          effect_size = eff,
          effect_magnitude = mag
        )
      }
    } else {
      cat("Interaction not significant for", op,
          "- per-level comparisons skipped.\n")
    }
  }

  anova_res <- bind_rows(anova_rows)
  pairwise_res <- bind_rows(pairwise_rows)

  # BH correction is applied within each response-specific analysis.
  all_p <- c(anova_res$p, pairwise_res$p)
  all_p_adj <- p.adjust(all_p, method = "BH")
  anova_res$p_adj <- all_p_adj[seq_len(nrow(anova_res))]
  anova_res$significant <- anova_res$p_adj < ALPHA

  if (nrow(pairwise_res) > 0) {
    pairwise_res$p_adj <- all_p_adj[
      nrow(anova_res) + seq_len(nrow(pairwise_res))
    ]
    pairwise_res$significant <- pairwise_res$p_adj < ALPHA
  }

  cat("\n", analysis_name, " - factorial tests:\n", sep = "")
  print(anova_res, width = Inf)
  cat("\n", analysis_name, " - pairwise comparisons:\n", sep = "")
  print(pairwise_res, width = Inf)

  if (save) {
    save_table(
      anova_res,
      paste0(analysis_name, "_anova"),
      paste("Factorial tests of library and library x payload interaction on",
            response_label, "(BH-adjusted p-values)"),
      4
    )
    if (nrow(pairwise_res) > 0) {
      save_table(
        pairwise_res,
        paste0(analysis_name, "_pairwise"),
        paste("Pairwise json vs orjson comparisons by payload for",
              response_label, "(BH-adjusted p-values)"),
        4
      )
    }
  }

  invisible(list(
    anova = anova_res,
    pairwise = pairwise_res,
    approach = approach,
    response = response,
    analysis = analysis_name
  ))
}

# =============================================================================
# STAGE 6: interaction plot (RQ1.1)
# =============================================================================
plot_interaction <- function(dat, save = TRUE) {
  p <- dat %>%
    group_by(operation, payload, library) %>%
    summarise(median_eff = median(efficiency_uJ_per_KB), .groups = "drop") %>%
    ggplot(aes(x = payload, y = median_eff, colour = library, group = library)) +
    geom_point(size = 1.5) + geom_line() +
    facet_wrap(~ operation, labeller = op_labels) +
    scale_colour_manual(values = lib_colours) +
    labs(x = "Payload complexity", y = expression("Median energy efficiency (" * mu * "J/KB)"),
         colour = "Library")
  if (save) save_fig(p, "interaction_rq1_1.pdf", FULL_W, 2.4)
  invisible(p)
}

# =============================================================================
# STAGE 7: sensitivity check without the flagged outliers
# Repeats the tests on runs not flagged (energy or time, 1.5 x IQR) for the
# same response variable as the main analysis. Each RQ has distinct output files.
# =============================================================================
sensitivity_check <- function(
    dat,
    main_res,
    approach = NULL,
    response = main_res$response,
    save = TRUE
) {
  d <- dat %>% filter(!outlier_any)
  cat(
    "\nSensitivity check for", response, ": removed",
    nrow(dat) - nrow(d), "flagged runs, kept", nrow(d), "\n"
  )

  sens <- test_rq1(
    d,
    approach = approach,
    response = response,
    save = FALSE
  )

  cmp_anova <- main_res$anova %>%
    select(operation, term, p_adj_main = p_adj, sig_main = significant) %>%
    left_join(
      sens$anova %>%
        select(operation, term, p_adj_sens = p_adj, sig_sens = significant),
      by = c("operation", "term")
    ) %>%
    mutate(same_conclusion = sig_main == sig_sens)

  cmp_pair <- NULL
  if (nrow(main_res$pairwise) > 0 && nrow(sens$pairwise) > 0) {
    cmp_pair <- main_res$pairwise %>%
      select(operation, payload, rel_diff_pct_main = rel_diff_pct,
             p_adj_main = p_adj, sig_main = significant) %>%
      left_join(
        sens$pairwise %>%
          select(operation, payload, rel_diff_pct_sens = rel_diff_pct,
                 p_adj_sens = p_adj, sig_sens = significant),
        by = c("operation", "payload")
      ) %>%
      mutate(same_conclusion = sig_main == sig_sens)
  }

  cat("\nMain vs without outliers - factorial tests:\n")
  print(cmp_anova, width = Inf)
  if (!is.null(cmp_pair)) {
    cat("\nMain vs without outliers - per-level comparisons:\n")
    print(cmp_pair, width = Inf)
  }

  all_same <- all(cmp_anova$same_conclusion, na.rm = TRUE) &&
    (is.null(cmp_pair) || all(cmp_pair$same_conclusion, na.rm = TRUE))
  cat("\nAll conclusions unchanged:", all_same, "\n")

  if (save) {
    save_table(
      cmp_anova,
      paste0("sens_", main_res$analysis, "_anova"),
      paste("Sensitivity analysis for", response,
            "- factorial tests with and without flagged outliers"),
      4
    )
    if (!is.null(cmp_pair)) {
      save_table(
        cmp_pair,
        paste0("sens_", main_res$analysis, "_pairwise"),
        paste("Sensitivity analysis for", response,
              "- per-level comparisons with and without flagged outliers"),
        4
      )
    }
  }

  invisible(list(anova = cmp_anova, pairwise = cmp_pair, results = sens))
}

# =============================================================================
# Run everything at once (only for Rscript, not when sourced interactively)
# =============================================================================
main <- function() {
  dat <- clean_data()
  describe_data(dat)
  plot_distributions(dat)
  plot_qq_efficency(dat)
  plot_qq_energy(dat)

  # RQ1: total energy consumption (J)
  assumptions_energy <- check_assumptions(dat,response = "energy_J",file_prefix = "RQ1_energy")
  approach_energy <- choose_approach(assumptions_energy)
  res_rq1 <- test_rq1(dat,approach = approach_energy,response = "energy_J")
  sensitivity_check(dat,main_res = res_rq1,approach = approach_energy,response = "energy_J")

  # RQ1.1: energy efficiency (J/KB)
  assumptions_efficiency <- check_assumptions(dat,response = "efficiency_J_per_KB",file_prefix = "RQ1_1_efficiency")
  approach_efficiency <- choose_approach(assumptions_efficiency)
  res_rq1_1 <- test_rq1(dat,approach = approach_efficiency,response = "efficiency_J_per_KB")
  plot_interaction(dat)
  sensitivity_check(dat,main_res = res_rq1_1,approach = approach_efficiency,response = "efficiency_J_per_KB")

  cat("\nDone. Figures in", FIG_DIR, "- tables in", TAB_DIR, "\n")
  invisible(list(rq1 = res_rq1, rq1_1 = res_rq1_1))
}

if (!interactive() && sys.nframe() == 0) main()