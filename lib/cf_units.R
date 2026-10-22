# =============================================================================
# Crayfisher shared: groundwater flow units
# =============================================================================
# PUBLIC MODULE — this file ships to the public mirrors via tools/assemble.sh
# (SHARED_LIB). Keep it free of model-specific, proprietary or LLM content.
#
# MODFLOW works in the model's own length/time units; every Crayfisher app that
# shows a flow has to convert to something a hydrogeologist reads. That mapping
# is domain knowledge, not app logic, so it lives in one place — apps/mf_lst
# previously carried the factors inline in a radioButtons() call, where they
# were invisible to every other app and impossible to test.
#
# Factors assume the model's flow unit is m3/day, which is true for every
# Crayfisher model to date. Anything else needs an explicit conversion first.
# =============================================================================

# Multiply an m3/day value by the factor to get the target unit.
#   L/s   : 1000 L/m3 / 86400 s/day = 0.0115740740740741
#   GL/a  : 365 day/a / 1e6 m3/GL   = 0.000365
CF_FLOW_UNITS <- list(
  "m3/d" = list(label = "m³/d", factor = 1),
  "L/s"  = list(label = "L/s",      factor = 1000 / 86400),
  "GL/a" = list(label = "GL/a",     factor = 365 / 1e6)
)

#' Named vector for a Shiny radioButtons()/selectInput() choice list.
cf_flow_unit_choices <- function() {
  stats::setNames(names(CF_FLOW_UNITS), vapply(CF_FLOW_UNITS, `[[`, character(1), "label"))
}

#' Display label for a unit key ("L/s" -> "L/s", "m3/d" -> "m³/d").
cf_flow_unit_label <- function(unit = "m3/d") {
  u <- CF_FLOW_UNITS[[unit]]
  if (is.null(u)) unit else u$label
}

#' Convert a flow in m3/day to `unit`, with an optional multiplier.
#'
#' `multiplier` carries the cross-section / area factor some analyses need
#' (mf_lst exposes it as "Multiplier (e.g. cross-section)"); it is applied
#' before the unit conversion so the two stay independent.
cf_convert_flow <- function(value, unit = "m3/d", multiplier = 1) {
  u <- CF_FLOW_UNITS[[unit]]
  if (is.null(u)) stop("Unknown flow unit: ", unit,
                       ". Known: ", paste(names(CF_FLOW_UNITS), collapse = ", "))
  as.numeric(value) * as.numeric(multiplier) * u$factor
}

#' Rate -> cumulative volume over time.
#'
#' `rate` is per day and `days` the length of each step, so the running total is
#' in the model's volume unit (m3 for an m3/day rate). Kept separate from
#' cf_convert_flow because a cumulative volume is NOT a flow — converting it
#' with a flow factor would be wrong, which is exactly the mistake this
#' separation is meant to prevent.
cf_cumulative_volume <- function(rate, days) {
  stopifnot(length(rate) == length(days))
  cumsum(as.numeric(rate) * as.numeric(days))
}
