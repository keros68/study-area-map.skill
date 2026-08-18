# relief_basemap.R -- reusable pieces for study-area location maps
#
# Self-contained: source this file and nothing else is required. The constants
# below are set only if they do not already exist, so loading this alongside a
# house-style preamble that defines LW / TXT_GG leaves those definitions alone.
#
# Nothing here is project-specific. Set the region constants at the top of your
# figure script, not in this file, so several figures in one paper can share it.

suppressPackageStartupMessages({
  library(ggplot2); library(sf); library(terra); library(tidyterra)
  library(systemfonts); library(ragg)
})

# 1 pt in mm, which is what ggplot2 linewidth takes. Structural lines (panel
# border, ticks) sit at LW; data lines need to be clearly heavier or they are
# indistinguishable from the frame at 60-100 mm panel widths.
if (!exists("LW"))     LW     <- 25.4 / 72
if (!exists("LW_DAT")) LW_DAT <- LW * 1.8
if (!exists("TXT_PT")) TXT_PT <- 8
# element_text(size =) is points; geom_text(size =) and annotate(size =) are
# millimetres. In-panel text must use TXT_GG or it comes out about 2.8x too big.
if (!exists("TXT_GG")) TXT_GG <- TXT_PT / ggplot2::.pt

# Detect, register a fallback, then assert. Default R devices cannot find Arial
# in the PostScript font database, so text measurement silently misbehaves
# unless a font-aware device and a registered family are both in place.
ensure_font <- function(family = "Arial") {
  if (family %in% systemfonts::system_fonts()$family) return(invisible(family))
  cand <- c(Sys.glob(file.path(Sys.getenv("WINDIR"), "Fonts", "arial.ttf")),
            Sys.glob("/usr/share/fonts/**/LiberationSans-Regular.ttf"),
            Sys.glob("/usr/share/fonts/**/DejaVuSans.ttf"),
            Sys.glob("/System/Library/Fonts/Supplemental/Arial.ttf"))
  if (length(cand)) systemfonts::register_font(family, plain = cand[[1]])
  if (!family %in% systemfonts::system_fonts()$family)
    stop(sprintf("font '%s' not available and no metric-compatible fallback found", family))
  invisible(family)
}
ensure_font()

# Minimal publication theme for map panels: one text size, a black frame, no
# grid, white background. Frame weight is heavier than a statistical panel
# because a map frame also has to hold against a full-bleed raster.
theme_map_pub <- function(base_pt = TXT_PT, lw = LW * 1.7, family = "Arial") {
  theme_classic(base_size = base_pt, base_family = family) +
    theme(
      text        = element_text(family = family, size = base_pt, colour = "black"),
      axis.text   = element_text(family = family, size = base_pt, colour = "black"),
      axis.title  = element_blank(),
      axis.line   = element_blank(),
      axis.ticks  = element_line(colour = "black", linewidth = LW),
      panel.grid  = element_blank(),
      panel.border     = element_rect(colour = "black", fill = NA, linewidth = lw),
      panel.background = element_rect(fill = "white", colour = NA),
      plot.background  = element_rect(fill = "white", colour = NA),
      plot.margin      = margin(2, 2, 2, 2, "mm"))
}

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

# Combined bbox of several layers, in one CRS.
#
# A country panel window must come from every layer that has to fit inside it,
# not from whichever one is handy. Boundary-line layers in particular are often
# partial -- disputed segments, maritime lines -- so their bbox can fall far
# short of the polygon layer and silently amputate the map.
bbox_union <- function(...) {
  bs <- lapply(list(...), sf::st_bbox)
  c(xmin = min(vapply(bs, function(b) b[["xmin"]], numeric(1))),
    xmax = max(vapply(bs, function(b) b[["xmax"]], numeric(1))),
    ymin = min(vapply(bs, function(b) b[["ymin"]], numeric(1))),
    ymax = max(vapply(bs, function(b) b[["ymax"]], numeric(1))))
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

# Mosaic DEM tiles onto the target grid and assert the no-data fraction.
#
# Tiles are projected one by one onto a single template covering the window,
# then merged. Merging first fails outright when tiles sit in different UTM
# zones, and projecting each tile independently leaves seams where the output
# grids do not align.
#
# The assertion is the point: a window that overruns tile coverage leaves a
# blank sliver on one frame edge that hides under a scale bar in preview and
# survives to the journal.
#
#   src      directory of tiles, or a character vector of file paths.
#            GDAL virtual paths work, so zipped tiles need no unpacking:
#            "/vsizip/D:/dem/ASTGTM_N37E111.img.zip/ASTGTM_N37E111V.img"
#   pattern  regex selecting tiles inside `src`. NULL means `src` is already
#            the file list.
#   crs      target CRS (proj string, WKT, or an sf crs object)
#   win      c(xmin, xmax, ymin, ymax) in the target CRS
#   fact     aggregation factor applied before reprojection (speed vs detail)
#   res      output cell size in target CRS units. NULL derives it from the
#            first tile.
load_dem <- function(src, pattern = NULL, crs, win, fact = 3, res = NULL,
                     max_na = 0.001) {
  if (inherits(crs, "crs")) crs <- crs$wkt         # terra::project rejects sf crs
  files <- if (is.null(pattern)) src
           else list.files(src, pattern = pattern, full.names = TRUE)
  stopifnot(length(files) > 0)

  rs <- lapply(files, rast)
  if (fact > 1) rs <- lapply(rs, aggregate, fact = fact, fun = "mean", na.rm = TRUE)
  if (is.null(res)) res <- terra::res(project(rs[[1]], crs, method = "near"))[1]

  tmpl <- rast(ext(win[["xmin"]], win[["xmax"]], win[["ymin"]], win[["ymax"]]),
               crs = crs, resolution = res)
  rs <- lapply(rs, function(r) project(r, tmpl, method = "bilinear"))
  d <- if (length(rs) == 1) rs[[1]] else do.call(terra::merge, rs)
  names(d) <- "elev"

  na <- global(is.na(d), "mean", na.rm = FALSE)[[1]]
  cat(sprintf("[DEM] %d tile(s), %s cells, %.0f m, no-data %.3f%%
",
              length(files), paste(dim(d)[1:2], collapse = "x"), res, 100 * na))
  stopifnot(na <= max_na)
  d
}

# Build GDAL virtual paths into zipped tiles, so DEM archives need no unpacking.
# ASTER and SRTM downloads arrive zipped, and the member filename usually
# carries an arbitrary suffix, so it has to be read from the archive rather
# than constructed.
#
#   dir      directory holding the .zip archives
#   pattern  regex selecting archives
#   inner    regex selecting the raster inside each archive
vsizip_tiles <- function(dir, pattern = "[.]zip$", inner = "[.](img|tif|hgt)$") {
  zips <- list.files(dir, pattern = pattern, full.names = TRUE)
  stopifnot(length(zips) > 0)
  out <- vapply(zips, function(z) {
    m <- utils::unzip(z, list = TRUE)$Name
    m <- m[grepl(inner, m, ignore.case = TRUE)]
    if (!length(m)) NA_character_ else file.path("/vsizip", z, m[1])
  }, character(1), USE.NAMES = FALSE)
  bad <- zips[is.na(out)]
  if (length(bad)) warning("no raster member in: ", paste(basename(bad), collapse = ", "))
  out[!is.na(out)]
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

# In-panel furniture must clear the panel border. A block whose edge lands on
# the frame reads as a drawing error: at 8 pt the block's own hairline and the
# frame merge into one thick broken line, and the reader cannot tell which is
# the map edge. FRAME_PAD is the clearance every built-in block leaves, as a
# fraction of panel width or height.
FRAME_PAD <- 0.025

# Assert a fractional block sits inside the panel with clearance. The built-in
# helpers call it themselves; call it for anything hand-placed.
assert_inside <- function(x, y, pad = FRAME_PAD, what = "block") {
  bad <- c(if (min(x) < pad) "left", if (max(x) > 1 - pad) "right",
           if (min(y) < pad) "bottom", if (max(y) > 1 - pad) "top")
  if (length(bad)) stop(sprintf(
    "%s reaches the %s frame (x %.3f-%.3f, y %.3f-%.3f, clearance %.3f required). Move it inward.",
    what, paste(bad, collapse = " and "), min(x), max(x), min(y), max(y), pad))
  invisible(TRUE)
}

# Fraction -> data coordinate helpers for a window.
frac_fun <- function(win) list(
  fx = function(t) win[["xmin"]] + t * (win[["xmax"]] - win[["xmin"]]),
  fy = function(t) win[["ymin"]] + t * (win[["ymax"]] - win[["ymin"]]))

# Slim needle north arrow. Width is derived from the window aspect so the needle
# keeps its shape in panels of different proportions.
north_needle <- function(win, ax = 0.055, ay = 0.928, h = 0.060, slim = 0.22,
                         col = "black") {
  # ay is the tip; the N label sits above it, so the block top is ay + 0.045
  assert_inside(c(ax - 0.03, ax + 0.03), c(ay - h, ay + 0.045), what = "north arrow")
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
                        x = c(0.630, 0.945), y_bar = c(0.064, 0.090),
                        y_title = 0.112, y_tick = 0.048) {
  stopifnot(length(labs) == length(cols) - 1)
  assert_inside(x, c(y_tick - 0.015, y_title + 0.015), what = "elevation legend")
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
legend_backing <- function(win, x = c(0.596, 0.972), y = c(0.032, 0.148),
                           alpha = 0.88) {
  assert_inside(x, y, what = "legend backing")
  f <- frac_fun(win)
  annotate("rect", xmin = f$fx(x[1]), xmax = f$fx(x[2]),
           ymin = f$fy(y[1]), ymax = f$fy(y[2]),
           fill = "white", alpha = alpha, colour = "grey35", linewidth = LW * 0.6)
}

# ---- corner inset ----
# Physical aspect ratio of a fractional box inside a panel. The panel is in
# projected units with equal x/y scaling, so the fraction ratio times the window
# ratio IS the printed ratio.
inset_aspect <- function(win, x, y) {
  ((x[2] - x[1]) * (win[["xmax"]] - win[["xmin"]])) /
  ((y[2] - y[1]) * (win[["ymax"]] - win[["ymin"]]))
}

# Place a plot into a fractional box of the parent panel, in the parent's data
# coordinates. Size the inset's own window with fit_aspect(win, inset_aspect(...))
# first, or coord_sf letterboxes inside the box and its edges stop aligning.
#
# Before using this, check the leader rule: a leader pair fans across the whole
# side of the panel that faces the next panel, so an inset cannot share that side.
corner_inset <- function(p, win, x = c(0.795, 0.988), y = c(0.015, 0.400)) {
  # Strip the inset's own margins, page background and legend before embedding.
  # annotation_custom draws the WHOLE grob, so a plot.margin and an opaque
  # plot.background become a white slab that covers the parent map and pushes
  # the panel inward, where coord_sf then letterboxes it a second time. With
  # these zeroed the grob is the panel, and the box aspect is the panel aspect.
  p <- p + theme(plot.margin = margin(0, 0, 0, 0),
                 plot.background = element_blank(),
                 legend.position = "none")
  f <- frac_fun(win)
  annotation_custom(ggplotGrob(p), xmin = f$fx(x[1]), xmax = f$fx(x[2]),
                    ymin = f$fy(y[1]), ymax = f$fy(y[2]))
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

# Data-source footer: one small line under the composed figure.
#
# The caption is where a journal expects sources, but figures get lifted out of
# manuscripts into slides and reviews, and the caption does not travel with
# them. A footer line keeps the attribution attached to the image.
#
# Returns the wrapped grob and the new total height, since the footer adds to it.
credit_footer <- function(g, text, fig_h_mm, h_mm = 4.2, pt = 6,
                          col = "grey30", pad_l = 2) {
  lab <- grid::textGrob(text, x = grid::unit(pad_l, "mm"), hjust = 0,
                        gp = grid::gpar(fontfamily = "Arial", fontsize = pt, col = col))
  list(grob = gridExtra::arrangeGrob(g, lab, ncol = 1,
                                     heights = grid::unit(c(fig_h_mm, h_mm), "mm")),
       height_mm = fig_h_mm + h_mm)
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
