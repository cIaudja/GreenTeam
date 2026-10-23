# =============================================================================
# main.R - full data analysis pipeline (json vs orjson, Green Lab 2026/2027)
#
# Run from the root of the repository:
#   Rscript main.R
#
# 1. Synthetic block  (RQ1, RQ1.1) -> data-analysis/synthetic_analysis_v3.R
#    input:  results/synthetic_all.csv
#    output: data-analysis/{figures,tables,processed}/synthetic_v3/
# 2. Real-world block (RQ2.1-RQ2.3) -> data-analysis/analysis_realworld.R
#    input:  results/real_world_all.csv
#    output: data-analysis/{figures,tables,processed}/ (rw_*, rq2_*)
# =============================================================================

if (!file.exists("results/synthetic_all.csv")) {
  stop("Run main.R from the root of the repository.")
}

cat("\n===== Synthetic block (RQ1, RQ1.1) =====\n")
synthetic <- new.env()
sys.source("data-analysis/synthetic_analysis_v3.R", envir = synthetic)
synthetic$main()

cat("\n===== Real-world block (RQ2.1-RQ2.3) =====\n")
sys.source("data-analysis/analysis_realworld.R", envir = new.env())

cat("\nAll analyses done.\n")
