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
# This file is the single shared copy. Each app sees it at lib/cf_theme.R —
# via a symlink during development, and copied in when its image is built —
# so the source() call above is identical in every app.
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
  base_font = bslib::font_google("Space Grotesk"),
  heading_font = bslib::font_google("Space Grotesk"),
  bg = CF_BG,
  fg = CF_FG
)

# Custom CSS for the vivid, glowing look (matches the website's neon accents).
# Literal hex values here mirror the CF_* constants above; keep them aligned.
cf_custom_css <- "
  @import url('https://fonts.googleapis.com/css2?family=Orbitron:wght@500..800&display=swap');
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
  /* Phones / narrow windows: the absolutely positioned links sat ON TOP of the
     title (found on a phone 2026-10-06). Below 768px they flow onto their own
     line under the title, wrapping if needed, and the title shrinks a little. */
  @media (max-width: 768px) {
    .navbar .bslib-page-title, .navbar .navbar-brand { display: flex !important; flex-wrap: wrap; align-items: center; gap: 6px; white-space: normal; width: 100%; }
    .app-title-text { font-size: 1rem; line-height: 1.25; }
    .app-beta-badge { margin-left: 8px; padding: 2px 9px; font-size: 0.7rem; }
    .app-header-links { position: static !important; transform: none !important; flex-wrap: wrap; gap: 6px; width: 100%; margin-top: 4px; }
    .app-header-links .btn { font-size: 0.75rem; padding: 2px 10px; }
  }
  h1, h2, h3, h4 { color: #00bc8c; }
  /* Only actual Crayfisher brand references get the wordmark font (Orbitron);
     matches the website scoping, which keeps it off general headings/body text. */
  .app-back-btn { font-family: 'Orbitron', sans-serif; }
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


# Browser-tab icon: the Crayfisher logo as a solid teal silhouette on a
# transparent background (the logo's dark square showed as a black box in
# light tabs), with a thin dark-teal outline so it also reads on light tabs
# (2026-10-08), 32 px, inline so no static-file
# plumbing is needed in any app or build context (2026-10-08; was a blank or
# emoji icon). Use inside the page: tags$head(cf_favicon_tag()).
cf_favicon_tag <- function() {
  htmltools::tags$link(rel = "icon", type = "image/png", href = paste0(
    "data:image/png;base64,",
    "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAMAAABEpIrGAAACH1BMVEUAAAAUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYUuJYLeWQLemULd2IOkHYJbVsJblsKdmIHXE4MgWsOkXcHXU4MgmsHX1AKc18HXk8IZFQKb10NiHAHW0wNh28JblwIY1MJalgPlXoOj3YIZlYOjnUKcF0PlXsJaVcHWkwNhW4Ni3MHW00KdWEMhW0HXE0MgmwIZVUKcV4MgWoMfmkKdGAPlHkIZlUNi3IPmX0IaFcMg2wLeGQKdGEOjXQKc2AJalkPmH0NjHMLd2MQoIMPl3wRpYcTtJMTs5IRp4gLfmgPmn8Pmn4Le2YRp4kRpIYQnYEOkngRo4USr48QnoESrIwSqosQooQQn4ISrY0Nhm8Qm38SsI8MfmgRqIkJaVgSrI0Sq4sRooUMgGoJaFcQnoIPlnsLfGYTtZMRqIoNinIQnIATtpUUuJYTtpQIZVQKcl8Nhm4HYFEQoYQSro4TspELfWcHYFAJbFoJb1wOk3gNiXETt5UTsZEOj3UOjHQOkHcSqYoPlHoPmX4QnYATsZASq4wMhG0TsJAIZ1YLfWjcHKtEAAAANXRSTlMAARIwSSklSjEUAgobIRgGSCcJHxwNBCM6LhFVUys3Rk1CHSIgLS81Aws2NDkyFTgqFxoHE9+oddYAAALGSURBVDjLdVP3Q1JRFL4PK80BooZl25YtywzCwXM8AjSZDx+ipDIElPGQ0icSigwjB2GoQCVWSpY2tPoDe4SIin2/3O+MO8453wXgHyBKzrHjENgFdCI372Q+yKCgsIhKKyimp216cQmNWlp2Kr0DYpRQyk+fqThLTdnUc5TzF+iUEga07xBAO3Exl8lIMgbr0mU6DWSj4hG7LrnWsxsqwJFo5MCNADTBzY3gP2hhtwLQykaOikHcSvJJj3l8vqCNtCrboUMJTzpIP0CEIpG4iSQSqWz/bgig8k6MZKhcoehCSaIUdqNJfwo9VwDSIcHyAQRUT3sl5JKP9fU3gSJ1Kq7USIBMqxto0Bt0PWKjWjeo6BsYMqmByoylqoMtoM+qxm3D9mfPR0aJMbvdgcvGVYDpVKaOMDiRoRdMlmtCMOme8ti8Pv80wfSIENiQbpCGQF9ajYGJV5yxmdm5+eBrt9FDoESnMl2GLiTBFmxGDi6YeTMcHpB2iwMsfps0mCl00L+oFi8FBbblSCRq5QWXjDHeyOBe+KoE4Wr8JmfI4LdHIt7QW6nT719sRySlu32qe2due0+scIjx+Oqqyz3r/8CZY32s18g/pToFAWxtfYSnNbETrs8brmhc8MWEy7VwPR9kBtKi+jqVSJjikeVoJB5K8DxmVcuhaXGdML7piHvDWyvGEOzkHh43ZsC1/fi3sDcwJeyHtd8blAfjyPwPn8W3KXXZf8bXhT4Lz9N84ApRZ5dCBVD+fHzDtb3AR0Gr3ifWZeJ8gR7Nu0YSi9vltulJcv0Gn0hgewlVdTdBXnlSSLPT8YAk+XVuAWSt6oCmbheSL9kJTLodO+TtpXcyetrF3Wogw92egA3fGh0C1HtZsr5fjSaWt2ZWf4W3o2a0Jicr4QEV/P6z5LBOrIz36kBNWVZCbTUp6pg6xo1xSVk/rE37/wIXrcl/XhQTBQAAAABJRU5ErkJggg=="))
}
