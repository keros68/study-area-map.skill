# palettes.R — hypsometric ramps and class breaks
#
# The skill ships ramps, not breaks. Breaks must come from the region's own
# elevation distribution: a coastal plain and a plateau basin need different
# class edges, and reusing another paper's edges produces a map where every
# class boundary falls in the wrong place.

# ---- ramps ----
# Each entry is a set of anchor colours, low to high. pal_hypso() interpolates
# them to whatever class count the figure needs.
#
#   terrain  green lowland -> yellow -> orange -> red-brown. General purpose.
#   arid     pale sage -> straw -> tan -> deep brown. For basins where green
#            lowland would falsely suggest vegetation.
#   alpine   deep green -> olive -> grey-brown -> pale rock. For high relief
#            where the top class should read as bare rock, not "hottest".
#   muted    the terrain ramp desaturated, for a basemap under heavy overlays
#            (an alternative to relief_rgb(wash =) when you want a fixed set).
HYPSO_ANCHORS <- list(
  terrain = c("#6BA857", "#A6CB7E", "#DED28A", "#EEBB6C", "#DB8756", "#AF5138"),
  arid    = c("#9DBE86", "#C6CE95", "#E3D6A0", "#DFB87E", "#C08E62", "#9A6B4C"),
  alpine  = c("#3F7A4E", "#7CA063", "#B0B382", "#C3AE8E", "#B69C90", "#D8CEC6"),
  muted   = c("#A6C79A", "#C8D9AE", "#E7E2BE", "#EFD5AF", "#E0B6A0", "#C99287")
)

pal_hypso <- function(name = "terrain", n = 6) {
  stopifnot(name %in% names(HYPSO_ANCHORS), n >= 3)
  grDevices::colorRampPalette(HYPSO_ANCHORS[[name]], space = "Lab")(n)
}

# Neutral ramp for land outside the region of interest, plus a sea ramp.
# Used for the "mask to emphasise" treatment in a country panel.
PAL_SURROUND <- c("#BCD5E6", "#CBDFEC", "#D9E8F2", "#E5F0F7",   # sea, deep -> shallow
                  "#EBE8E2", "#E0DCD4", "#D2CDC3")              # land, low -> high
BRK_SURROUND <- c(-1e5, -4000, -1000, -200, 0, 800, 2500, 1e5)

# ---- breaks from the data ----
# Round-number class edges spanning the DEM's central range. Tails are absorbed
# by the open end classes, so a single snow peak or one sea-level cell cannot
# stretch the ramp and flatten everything else.
#
# Returns length n+1 with +/-1e5 sentinels, ready for relief_rgb().
elev_breaks <- function(d, n = 6, probs = c(0.02, 0.98),
                        steps = c(10, 20, 25, 50, 100, 125, 200, 250, 500, 1000)) {
  stopifnot(n >= 3)
  s <- terra::spatSample(d, min(1e5, terra::ncell(d)), method = "regular",
                         na.rm = TRUE, as.df = TRUE)[, 1]
  q <- stats::quantile(s, probs, na.rm = TRUE)
  step <- steps[which.min(abs(steps - diff(q) / (n - 1)))]
  lo <- ceiling(q[[1]] / step) * step
  inner <- lo + step * seq_len(n - 1) - step
  cat(sprintf("[breaks] p%g-p%g = %.0f-%.0f m, step %g -> %s\n",
              100 * probs[1], 100 * probs[2], q[[1]], q[[2]], step,
              paste(inner, collapse = ", ")))
  c(-1e5, inner, 1e5)
}

# Tick labels for elev_legend(): one per interior boundary, blanking all but
# every `every`-th. Six classes with five 8 pt labels run together into
# "10001250150017502000".
elev_labels <- function(brks, every = 2) {
  inner <- brks[-c(1, length(brks))]
  lab <- format(inner, trim = TRUE, big.mark = "")
  lab[seq_along(lab) %% every != 1] <- ""
  lab
}

# ---- discipline ----
# The study-area accent colour must appear nowhere else in the figure. Call this
# after choosing point/line palettes; it compares in Lab space, because two
# reds that differ in hex can still read as the same colour in print.
assert_accent_unique <- function(accent, others, min_dist = 25) {
  lab <- function(x) grDevices::convertColor(t(grDevices::col2rgb(x)) / 255,
                                             "sRGB", "Lab")
  a <- lab(accent); o <- lab(others)
  dist <- sqrt(rowSums((o - matrix(a, nrow(o), 3, byrow = TRUE))^2))
  bad <- others[dist < min_dist]
  if (length(bad)) stop(sprintf(
    "accent %s collides with: %s (Lab distance %s < %g). Change the symbol's SHAPE, not the accent.",
    accent, paste(bad, collapse = ", "), paste(round(dist[dist < min_dist], 1), collapse = ", "),
    min_dist))
  invisible(TRUE)
}
