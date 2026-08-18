# relief_basemap.R — reusable pieces for study-area location maps
#
# Source this after the rfigure.skill preamble, which must already have defined
# LW, LW_DAT, TXT_PT, TXT_GG and registered Arial.
#
# Nothing here is project-specific. Set the constants at the top of your figure
# script, not in this file, so several figures in one paper can share it.

suppressPackageStartupMessages({library(sf); library(terra); library(tidyterra)})

stopifnot(exists("LW"), exists("TXT_GG"))

# ---------------------------------------------------------------- windows ----

# A lon/lat rectangle becomes a curved quadrilateral once projected. Its bbox
# leaves blank wedges at the frame corners; its inscribed rectangle is guaranteed
# to be covered by data on all four sides. Use this whenever a raster basemap has
# to reach the frame edge.
inscribed_window <- function(lon, lat, crs, n = 400) {
  to_m <- function(x, y) st_coordinates(st_transform(
    st_as_sf(data.frame(x = x, y = y), coords = c("x", "y"), crs = 4326), crs))
  sL <- to_m(rep(lon[1], n), seq(lat[1], lat[2], length.out = n))
  sR <- to_m(rep(lon[2], n), seq(lat[1], lat[2], length.out = n))
  sB <- to_m(seq(lon[1], lon[2], length.out = n), rep(lat[1], n))
  sT <- to_m(seq(lon[1], lon[2], length.out = n), rep(lat[2], n))
  c(xmin = max(sL[, 1]), xmax = min(sR[, 1]),
    ymin = max(sB[, 2]), ymax = min(sT[, 2]))
}

# Expand a window outward until it matches a slot's aspect ratio. Outward only,
# so nothing is cropped. Call this AFTER the slot size in mm is decided —
# coord_sf has a fixed aspect and will letterbox inside a mismatched slot,
# which is what makes multi-panel map frames come out unequal.
fit_aspect <- function(bb, target) {
  dx <- bb[["xmax"]] - bb[["xmin"]]; dy <- bb[["ymax"]] - bb[["ymin"]]
  if (dx / dy < target) {
    pad <- (target * dy - dx) / 2
    bb[["xmin"]] <- bb[["xmin"]] - pad; bb[["xmax"]] <- bb[["xmax"]] + pad
  } else {
    pad <- (dx / target - dy) / 2
    bb[["ymin"]] <- bb[["ymin"]] - pad; bb[["ymax"]] <- bb[["ymax"]] + pad
  }
  bb
}

win_aspect <- function(w) as.numeric((w[["xmax"]] - w[["xmin"]]) /
                                     (w[["ymax"]] - w[["ymin"]]))

# ------------------------------------------------------------------- DEM -----

# Merge DEM tiles, reproject, crop to the window, and assert the no-data
# fraction. The assertion is the point: a window that overruns tile coverage
# leaves a blank sliver on one frame edge that hides under a scale bar in
# preview and survives to the journal.
#
#   dir      directory of tiles
#   pattern  regex matching the tiles to use
#   crs      target CRS (proj string, WKT, or an sf crs object)
#   win      c(xmin, xmax, ymin, ymax) in the target CRS
#   fact     aggregation factor before reprojection (speed vs detail)
load_dem <- function(dir, pattern, crs, win, fact = 3, max_na = 0.001) {
  if (inherits(crs, "crs")) crs <- crs$wkt         # terra::project rejects sf crs
  files <- list.files(dir, pattern = pattern, full.names = TRUE)
  stopifnot(length(files) > 0)
  d <- if (length(files) == 1) rast(files) else do.call(terra::merge, lapply(files, rast))
  if (fact > 1) d <- aggregate(d, fact = fact, fun = "mean", na.rm = TRUE)
  d <- project(d, crs, method = "bilinear")
  d <- crop(d, ext(win[["xmin"]], win[["xmax"]], win[["ymin"]], win[["ymax"]]))
  names(d) <- "elev"
  na <- global(is.na(d), "mean", na.rm = FALSE)[[1]]
  cat(sprintf("[DEM] %s  no-data %.3f%%\n", paste(dim(d), collapse = "x"), 100 * na))
  stopifnot(na <= max_na)
  d
}

# Where are the no-data cells? Call this when load_dem's assertion fires — the
# fix depends on which edge is short. Returns panel-relative fractions.
locate_na <- function(d, win) {
  cells <- which(is.na(values(d)[, 1]))
  if (!length(cells)) return(invisible(NULL))
  xy <- xyFromCell(d, cells)
  fx <- (xy[, 1] - win[["xmin"]]) / (win[["xmax"]] - win[["xmin"]])
  fy <- (xy[, 2] - win[["ymin"]]) / (win[["ymax"]] - win[["ymin"]])
  cat(sprintf("[DEM] no-data n = %d  x %.3f-%.3f  y %.3f-%.3f\n",
              length(cells), min(fx), max(fx), min(fy), max(fy)))
  invisible(data.frame(fx = fx, fy = fy))
}

# --------------------------------------------------------------- relief ------

# Classed hypsometric tint MULTIPLIED by hillshade, emitted as an RGB raster.
#
# Multiplying is the whole point. Drawing a hypsometric raster over a hillshade
# at alpha < 1 interpolates every colour toward grey: raise alpha and the relief
# disappears, lower it and the colour does. Here the hillshade only scales
# brightness, so classes stay saturated and their boundaries stay crisp.
#
#   brks      length n+1 bin edges (use +/-1e5 for the open ends)
#   cols      length n colours, low to high
#   strength  light/shade swing; 0.35-0.45 for print, >0.55 swamps the classes
#   wash      lerp toward white; 0.20-0.30 for a basemap under many symbols
relief_rgb <- function(d, brks, cols, strength = 0.45, wash = 0,
                       alt = 40, azim = 315) {
  stopifnot(length(brks) == length(cols) + 1)
  sh <- shade(terrain(d, "slope",  unit = "radians"),
              terrain(d, "aspect", unit = "radians"), angle = alt, direction = azim)
  v   <- as.vector(values(d)[, 1])
  shv <- as.vector(values(sh)[, 1])
  ok  <- !is.na(v)
  shn <- shv / mean(shv, na.rm = TRUE) * 0.5      # mean -> 0.5 so f averages 1
  shn[is.na(shn)] <- 0.5
  f <- 1 + strength * pmin(pmax((shn - 0.5) * 2, -1), 1)

  cm  <- grDevices::col2rgb(cols) * (1 - wash) + 255 * wash
  idx <- findInterval(v, brks, rightmost.closed = TRUE, all.inside = TRUE)
  out <- matrix(NA_real_, length(v), 3)
  out[ok, ] <- t(cm[, idx[ok]]) * f[ok]

  r <- rast(d, nlyrs = 3)
  values(r) <- pmin(pmax(out, 0), 255)
  names(r) <- c("r", "g", "b")
  terra::RGB(r) <- 1:3
  r
}

# --------------------------------------------------------------- furniture ---

# Fraction -> data coordinate helpers for a window.
frac_fun <- function(win) list(
  fx = function(t) win[["xmin"]] + t * (win[["xmax"]] - win[["xmin"]]),
  fy = function(t) win[["ymin"]] + t * (win[["ymax"]] - win[["ymin"]]))

# Slim needle north arrow. Width is derived from the window aspect so the needle
# keeps its shape in panels of different proportions.
north_needle <- function(win, ax = 0.050, ay = 0.945, h = 0.062, slim = 0.22,
                         col = "black") {
  f <- frac_fun(win)
  w <- h * slim * (win[["ymax"]] - win[["ymin"]]) / (win[["xmax"]] - win[["xmin"]])
  tri <- data.frame(x = f$fx(c(ax, ax + w, ax, ax - w)),
                    y = f$fy(c(ay, ay - h, ay - h * 0.74, ay - h)))
  list(annotate("polygon", x = tri$x, y = tri$y, fill = col, colour = col,
                linewidth = LW * 0.5),
       annotate("text", x = f$fx(ax), y = f$fy(ay + 0.030), label = "N",
                size = TXT_GG, family = "Arial", colour = col))
}

# Hand-drawn elevation ramp. geom_spatraster_rgb() produces no guide, so the
# legend has to be drawn; doing it by hand also makes the position exact.
# `labs` must have length(cols) - 1 entries — one per interior boundary. Leave
# alternate entries "" or the labels run together at 8 pt.
elev_legend <- function(win, cols, labs, title = "Elevation (m)",
                        x = c(0.638, 0.962), y_bar = c(0.052, 0.078),
                        y_title = 0.100, y_tick = 0.036) {
  stopifnot(length(labs) == length(cols) - 1)
  f  <- frac_fun(win)
  nb <- length(cols)
  sw <- seq(x[1], x[2], length.out = nb + 1)
  list(
    annotate("rect", xmin = f$fx(sw[-(nb + 1)]), xmax = f$fx(sw[-1]),
             ymin = f$fy(y_bar[1]), ymax = f$fy(y_bar[2]), fill = cols, colour = NA),
    annotate("rect", xmin = f$fx(sw[1]), xmax = f$fx(sw[nb + 1]),
             ymin = f$fy(y_bar[1]), ymax = f$fy(y_bar[2]),
             fill = NA, colour = "grey25", linewidth = LW * 0.6),
    annotate("text", x = f$fx(mean(x)), y = f$fy(y_title), label = title,
             size = TXT_GG, family = "Arial", colour = "black"),
    annotate("text", x = f$fx(sw[2:nb]), y = f$fy(y_tick), label = labs,
             size = TXT_GG * 0.92, family = "Arial", colour = "black"))
}

# Translucent white backing for any in-panel block.
legend_backing <- function(win, x, y, alpha = 0.88) {
  f <- frac_fun(win)
  annotate("rect", xmin = f$fx(x[1]), xmax = f$fx(x[2]),
           ymin = f$fy(y[1]), ymax = f$fy(y[2]),
           fill = "white", alpha = alpha, colour = "grey35", linewidth = LW * 0.6)
}

# ------------------------------------------------------------- composition ---

# Pin a ggplot's panel cell to an exact size. respect = FALSE stops coord_fixed
# from re-constraining what has just been pinned.
pin_panel <- function(p, w_mm, h_mm) {
  g  <- ggplotGrob(p)
  pl <- g$layout[g$layout$name == "panel", ]
  g$widths[pl$l]  <- grid::unit(w_mm, "mm")
  g$heights[pl$t] <- grid::unit(h_mm, "mm")
  g$respect <- FALSE
  g
}

# Non-panel margins of a ggplot, in mm: how much width the axis labels and plot
# margins take, and how much height sits above and below the panel.
panel_margins <- function(p) {
  g  <- ggplotGrob(p)
  pl <- g$layout[g$layout$name == "panel", ]
  cw <- function(u) sum(as.numeric(grid::convertWidth(u, "mm")))
  ch <- function(u) sum(as.numeric(grid::convertHeight(u, "mm")))
  list(side = cw(g$widths[-pl$l]),
       left = cw(g$widths[seq_len(pl$l - 1)]),
       top  = ch(g$heights[seq_len(pl$t - 1)]),
       bot  = ch(g$heights[seq(pl$b + 1, length(g$heights))]))
}

# ggplotGrob() measures text against the CURRENT device. With none open it falls
# back to the default pdf device, where Arial does not exist — either an error
# or, worse, silently wrong widths that corrupt every mm computation after it.
# Wrap ALL grob building and unit conversion in this.
with_font_device <- function(expr, width_mm = 190, height_mm = 220) {
  tmp <- tempfile(fileext = ".png")
  ragg::agg_png(tmp, width = width_mm, height = height_mm, units = "mm", res = 72)
  on.exit({try(grDevices::dev.off(), silent = TRUE); unlink(tmp)}, add = TRUE)
  force(expr)
}

# A geographic box's position inside a panel, in mm from the figure's top-left.
# rect is c(x0, x1, yt, yb) in the same frame. Used for zoom leader endpoints.
box_in <- function(bb, wn, rect) {
  fxr <- function(v) rect[["x0"]] + (v - wn[["xmin"]]) /
    (wn[["xmax"]] - wn[["xmin"]]) * (rect[["x1"]] - rect[["x0"]])
  fyr <- function(v) rect[["yb"]] - (v - wn[["ymin"]]) /
    (wn[["ymax"]] - wn[["ymin"]]) * (rect[["yb"]] - rect[["yt"]])
  c(x0 = fxr(bb[["xmin"]]), x1 = fxr(bb[["xmax"]]),
    yt = fyr(bb[["ymax"]]), yb = fyr(bb[["ymin"]]))
}

# Dashed zoom leaders over a composed gtable. `segs` is a data.frame of
# x1, y1, x2, y2 in mm measured from the TOP; fig_h_mm flips them for grid.
#
# Before using these, check the collision rule: the leader pair fans across the
# whole side of the source panel that faces the target, so no corner inset can
# live on that side.
add_leaders <- function(base_grob, segs, fig_h_mm, col = "grey35") {
  leaders <- grid::segmentsGrob(
    x0 = grid::unit(segs$x1, "mm"), y0 = grid::unit(fig_h_mm - segs$y1, "mm"),
    x1 = grid::unit(segs$x2, "mm"), y1 = grid::unit(fig_h_mm - segs$y2, "mm"),
    gp = grid::gpar(col = col, lty = "22", lwd = LW / 0.353 * 0.7))
  grid::grobTree(base_grob, leaders)
}
