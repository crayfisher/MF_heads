# =============================================================================
# Crayfisher shared visual identity  (SINGLE SOURCE OF TRUTH)
# =============================================================================
# Every Crayfisher Shiny app sources this file so the showrooms read as one
# family, matching the website's Quarto `theme: vapor` (teal/neon on deep
# purple). Do NOT re-declare the palette or CSS inside an app — source this and,
# if the app needs extras, append to `cf_custom_css`:
#
#   source("lib/cf_theme.R")                       # after library(bslib)
#   custom_css <- paste0(cf_custom_css, "\n  /* app-specific rules */ ...")
#   ui <- page_sidebar(theme = bs_add_rules(app_theme, custom_css), ...)
#
# WHY lib/ AND NOT R/:  Shiny auto-sources every R/*.R file (loadSupport) BEFORE
# app.R runs — i.e. before the app's own library() calls. A theme module in R/
# would therefore execute before library(bslib) and fail with
# "could not find function bs_theme". Keeping it in lib/ + an explicit source()
# after the library() block gives predictable ordering. bslib calls are also
# namespace-qualified (bslib::) as insurance if an app sources this early.
#
# Monorepo note: this lives per-app for now (Docker build context); when the
# apps merge into my-shiny-platform it collapses to one shared lib/cf_theme.R.
# =============================================================================

CF_PRIMARY   <- "#00bc8c" # teal-green (site h1/h2 + buttons)
CF_ACCENT    <- "#32fbe2" # neon-teal (hover / highlight)
CF_SECONDARY <- "#6f42c1" # vapor purple
CF_BG        <- "#1a0933" # deep purple page background (vapor)
CF_PANEL     <- "#241046" # card / plot panel
CF_FG        <- "#ece7f7" # light lavender text
CF_MUTED     <- "#a99fce" # muted lavender (secondary text)

app_theme <- bslib::bs_theme(
  bootswatch = "vapor",
  primary = CF_PRIMARY,
  secondary = CF_SECONDARY,
  success = CF_PRIMARY,
  info = CF_ACCENT,
  base_font = bslib::font_google("Inter"),
  heading_font = bslib::font_google("Outfit"),
  bg = CF_BG,
  fg = CF_FG
)

# Custom CSS for the vivid, glowing look (matches the website's neon accents).
# Literal hex values here mirror the CF_* constants above; keep them aligned.
cf_custom_css <- "
  body { background: radial-gradient(circle at 20% 0%, #2a0f52 0%, #1a0933 55%) !important; }
  /* bslib's page-sidebar title bar derives its background + text colour from
     these two CSS vars; vapor sets them to pink bg / dark text. Pin both to the
     dark palette so the top bar is dark navy with readable teal text. */
  :root { --bslib-page-sidebar-title-bg: #150726 !important; --bslib-page-sidebar-title-color: #00bc8c !important; }
  .navbar, .bslib-page-sidebar > .navbar { background-color: #150726 !important; background-image: none !important; color: #00bc8c !important; border-bottom: 1px solid rgba(50,251,226,0.18) !important; box-shadow: none !important; position: relative; }
  .navbar .bslib-page-title { color: #00bc8c !important; font-weight: 700; }
  .navbar-brand { color: #00bc8c !important; font-weight: 700 !important; letter-spacing: 0.3px; text-shadow: 0 0 12px rgba(0,188,140,0.45); }
  /* Keep the title text + BETA pill together at the left (the page-title flex
     container would otherwise push a loose badge to the far right). */
  .app-title-wrap { display: inline-flex; align-items: center; }
  /* Large BETA pill next to the app title (matches the website apps badge). */
  .app-beta-badge { display: inline-block; margin-left: 12px; padding: 3px 13px; font-size: 0.78rem; font-weight: 800; letter-spacing: 1.5px; color: #1a0933; background: #32fbe2; border-radius: 30px; vertical-align: middle; text-shadow: none; box-shadow: 0 0 14px rgba(50,251,226,0.6); }
  /* Header link buttons (GitHub / report bug / back-to-site) grouped at the right
     of the top bar; explicit bright colour so they read at rest (outline-info
     rendered too dark on the dark bar). */
  .app-header-links { position: absolute !important; right: 16px; top: 50%; transform: translateY(-50%); z-index: 5; display: flex; gap: 8px; align-items: center; }
  .app-header-links .btn { color: #32fbe2 !important; border-color: #32fbe2 !important; background: rgba(50,251,226,0.08) !important; }
  .app-header-links .btn:hover { background: #32fbe2 !important; color: #150726 !important; box-shadow: 0 0 14px rgba(50,251,226,0.5) !important; }
  h1, h2, h3, h4 { color: #00bc8c; }
  .card {
    background: #241046 !important;
    border: 1px solid rgba(255,255,255,0.08) !important;
    border-radius: 14px !important;
    box-shadow: 0 8px 26px rgba(0,0,0,0.4) !important;
    transition: border-color 0.3s ease, box-shadow 0.3s ease;
  }
  .card:hover { border-color: #32fbe2 !important; box-shadow: 0 14px 30px rgba(50,251,226,0.18) !important; }
  .card-header { background: rgba(0,0,0,0.25) !important; border-bottom: 1px solid rgba(255,255,255,0.08) !important; color: #00bc8c !important; font-weight: 600 !important; }
  .sidebar { background: #150726 !important; border-right: 1px solid rgba(50,251,226,0.12) !important; }
  .accordion-button { background: #241046 !important; color: #ece7f7 !important; }
  .accordion-button:not(.collapsed) { background: #2d1657 !important; color: #00bc8c !important; box-shadow: inset 3px 0 0 #00bc8c; }
  .value-box { border-radius: 14px !important; border: 1px solid rgba(255,255,255,0.08) !important; }
  /* Buttons: pill shape + neon hover glow, matching the website cards. */
  .btn { border-radius: 30px !important; font-weight: 600 !important; transition: all 0.2s ease; }
  .btn-primary, .btn-success { background: #00bc8c !important; border: 1px solid #00bc8c !important; color: #04130e !important; }
  .btn-primary:hover, .btn-success:hover, .btn-info:hover { box-shadow: 0 0 16px rgba(0,188,140,0.55) !important; transform: translateY(-1px); }
  .btn-info { color: #04130e !important; }
  .btn-secondary { color: #ece7f7 !important; }
  /* Outline-info buttons (About panel: Source code / Report a bug): bright teal
     so they're clearly readable on the dark panel, not just on hover. */
  .btn-outline-info { color: #32fbe2 !important; border-color: #32fbe2 !important; }
  .btn-outline-info:hover { background: #32fbe2 !important; color: #150726 !important; box-shadow: 0 0 14px rgba(50,251,226,0.5) !important; }
  /* Outline buttons (e.g. Remove): keep text visible on the dark bg, not only on hover. */
  .btn-danger { color: #fff !important; }
  .btn-outline-danger { color: #ff7088 !important; border-color: #ff7088 !important; }
  .btn-outline-danger:hover { background: #ff7088 !important; color: #1a0933 !important; }
  .form-control, .form-select, .selectize-input, .selectize-dropdown { background: rgba(0,0,0,0.25) !important; border-color: rgba(255,255,255,0.12) !important; color: #ece7f7 !important; }
  a { color: #00bc8c; }
  a:hover { color: #32fbe2; }
"
