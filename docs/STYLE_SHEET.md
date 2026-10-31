# StarGazing Style Sheet

Derived from the reference design below. Colours were sampled from the image's pixels; sizes and
shadows were measured or estimated from it (a 430 px wide phone frame, treated as a 390 pt screen,
so 1 px is about 0.9 pt). Treat sizes as a starting point and confirm them against the designer's file.


**Status:** reference only. The app today uses a dark starfield theme (`StarGazing/UI/Theme.swift`);
adopting this sheet means replacing that file and restyling the three screens.

## 1. Principles

- **Light and airy.** A pale periwinkle canvas, with white cards floating on it.
- **One strong action.** A single saturated blue button per screen. Everything else is quiet.
- **Big, soft shapes.** Very round corners, no hard borders, long low-contrast shadows.
- **Heavy headings, light supporting text.** Navy bold titles over muted blue-gray detail.
- **Colour means something.** Blue is action and place, green is healthy, orange is a warning.

## 2. Colour

| Token | Hex | Used for |
|---|---|---|
| `canvasTop` | `#DBDFF0` | Page background, top-left of the gradient |
| `canvasBottom` | `#C6CDE8` | Page background, bottom-right of the gradient |
| `surface` | `#FFFFFF` | Cards and bottom sheets |
| `primary` | `#4B6DFC` | Primary button, route line, map pins, selected states |
| `primaryTint` | `#E6EAFF` | Secondary button background, selected chips |
| `textPrimary` | `#1C1E32` | Titles and values (navy, nearly black) |
| `textSecondary` | `#7D82A2` | Prices, subtitles, supporting lines |
| `textCaption` | `#9899AF` | Small labels above values |
| `divider` | `#F3F3F3` | 1 px rules inside a card |
| `heroTop` | `#4E93FF` | Top of the gradient hero circle |
| `heroBottom` | `#4AD8FD` | Bottom of the gradient hero circle (cyan) |
| `inverse` | `#33364E` | Dark round action button (white glyph) |
| `success` | `#44E55D` | Healthy or good state (the 80% battery) |
| `warning` | `#EAA94F` | Low or caution state (the 40% battery) |

**Gradients**
- Canvas: linear, top-left `canvasTop` to bottom-right `canvasBottom`.
- Hero circle: linear, `heroTop` to `heroBottom`, running roughly top-right to bottom-left.

**Map-style pattern.** The canvas carries a fine web of white lines (streets) with a slightly darker
patch for water. For StarGazing the equivalent is a faint constellation web: white lines and dots at
about 40-60% opacity over the canvas.

**Contrast.** `textPrimary` on white is about 16:1. White on `primary` is about 4.3:1, fine for the
17 pt semibold button label (large text) but not for small white text. `textSecondary` on white is
about 3.8:1, so use it for large text such as prices, not for small body copy. `textCaption` is about
2.8:1, so keep it to decoration or to labels paired with a clear value. Use `textSecondary` or darker
for any small text that carries meaning.

## 3. Typography

The reference uses a heavy geometric sans (a Gilroy/Circular-style face). A free match is
**Plus Jakarta Sans** (SIL Open Font License): https://github.com/tokotype/PlusJakartaSans (static
TTFs in `fonts/ttf/`). Bundle Regular, Medium, SemiBold, Bold and include its `OFL.txt`. If custom
fonts are not wanted, SF Pro Rounded (`.rounded` design) is the nearest system choice.

| Style | Size / line | Weight | Colour | Used for |
|---|---|---|---|---|
| `title` | 32 / 38 pt | Bold (700) | `textPrimary` | Screen and card titles ("Kick Scooter") |
| `cardTitle` | 22 / 27 pt | Bold (700) | `textPrimary` | Titles on small cards |
| `subtitle` | 20 / 26 pt | SemiBold (600) | `textSecondary` | Price or secondary headline |
| `value` | 25 / 30 pt | Bold (700) | `textPrimary` | Stat values ("40km.") |
| `body` | 15 / 20 pt | Medium (500) | `textPrimary` | Meta rows ("1,5 km", "80%") |
| `button` | 17 / 22 pt | SemiBold (600) | white on `primary` | Button labels |
| `caption` | 12 / 16 pt | Medium (500) | `textCaption` | Labels above stat values |

Titles sit tight (line height about 1.15). Numbers use the same bold face as titles. Support Dynamic
Type by scaling these with `relativeTo:` the nearest system text style.

## 4. Shape, spacing and elevation

- **Grid.** 8 pt base: 8, 16, 24, 32. Card inner padding about 38 pt on a 390 pt screen; use 24-32 pt
  on narrower layouts.
- **Corner radii (continuous corners).**
  - Screen frame and bottom sheet top corners: about 48-54 pt.
  - Cards: about 28 pt.
  - Primary and secondary buttons: about 20 pt.
  - Floating icon buttons: about 16 pt (rounded squares) or fully round.
- **Elevation.** Cards float with a soft, wide shadow: about `textPrimary` at 10% opacity, blur 40,
  y offset 16. Floating icon buttons use a smaller one: 8% opacity, blur 16, y offset 6. Nothing has
  an outline.
- **Bottom sheet.** White, top corners about 50 pt, a 28 x 4 pt drag handle centred 12 pt from the top
  in `divider`-to-`textCaption` gray.
- **Hairlines.** 1 px `divider` between a card's header and its stats row.

## 5. Components

**Primary button.** Height about 62 pt, radius 20 pt, fill `primary`, label `button` in white,
centred. Full width of the content, or flexing beside a secondary button.

**Secondary icon button.** Same height and radius as the primary, about 82 pt wide, fill
`primaryTint`, a 24 pt `primary` glyph. Sits to the right of the primary button with a 16 pt gap.

**Floating icon button.** 48 pt square, `surface` fill, radius 16 pt, a 2 pt-stroke navy glyph, the
small shadow above. Placed 24 pt from the screen edge, over the canvas. A round variant is used for
search and filters; a dark variant (`inverse` fill, white glyph) is the single "locate me" action.

**Hero circle.** A 260 pt circle filled with the hero gradient, with the subject (the scooter)
overlapping its edge so it breaks out of the shape. It sits at the top of a bottom sheet.

**Meta row.** A 15 pt icon plus `body` text, repeated with 24 pt between items: location pin in
`primary` or `textSecondary`, battery in `success` or `warning`.

**Stats row.** Three equal columns: `caption` label over `value`, separated from the title block by a
`divider` rule, with 16 pt above and 24 pt below.

**Card with overlapping image.** `surface`, radius 28 pt, the subject image overlaps the bottom
right corner and is allowed to leave the card. Title `cardTitle`, price `subtitle` in
`textSecondary`, battery meta at the bottom left.

**Map pins and route.** Teardrop pins in `primary` with a white centre dot; the route is a 4 pt
rounded `primary` line with square corners softened to about 12 pt.

## 6. Applying it to StarGazing

| Screen | Reference element | StarGazing equivalent |
|---|---|---|
| Choose photos | Page canvas, floating icon buttons, hero circle | Constellation canvas; hero circle holding the sparkle icon; picker row as a white card |
| Choose photos | Primary + secondary button pair | "Start stacking" (primary) beside a secondary button for the mode or photo count |
| Choose photos | Stats row | Mode selector as three columns: Clean sky, Median, Star trails, the chosen one in `primary` |
| Stacking | Route line over the canvas | Progress ring in `primary`; the photo cards drift around it on white cards |
| Result | Bottom sheet with hero image and stats | White sheet holding the before/after slider, with "photos stacked / skipped / time" as the stats row |
| Result | Primary + secondary pair | "Save to Photos" (primary) beside "Stack another set" (secondary) |
| Errors | Orange battery | `warning` for skipped photos and failures |

Night-sky photographs keep their own dark colours inside white cards; the light chrome frames them
rather than competing with them.

## 7. SwiftUI starting point

```swift
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum Style {
    static let canvasTop = Color(hex: 0xDBDFF0)
    static let canvasBottom = Color(hex: 0xC6CDE8)
    static let surface = Color.white
    static let primary = Color(hex: 0x4B6DFC)
    static let primaryTint = Color(hex: 0xE6EAFF)
    static let textPrimary = Color(hex: 0x1C1E32)
    static let textSecondary = Color(hex: 0x7D82A2)
    static let textCaption = Color(hex: 0x9899AF)
    static let divider = Color(hex: 0xF3F3F3)
    static let heroTop = Color(hex: 0x4E93FF)
    static let heroBottom = Color(hex: 0x4AD8FD)
    static let inverse = Color(hex: 0x33364E)
    static let success = Color(hex: 0x44E55D)
    static let warning = Color(hex: 0xEAA94F)

    static let sheetRadius: CGFloat = 50
    static let cardRadius: CGFloat = 28
    static let buttonRadius: CGFloat = 20
    static let iconButtonRadius: CGFloat = 16
}
```

Register bundled fonts with `UIAppFonts` in `Config/Info.plist` (one entry per file name), then use
`Font.custom("PlusJakartaSans-Bold", size: 32, relativeTo: .title)`.

## 8. Not in the reference

The image is static, so it says nothing about motion, dark mode, or empty and error states. For
StarGazing: keep the spring motion already in the app (cards folding into the star, the draggable
slider), honour Reduce Motion, and design dark mode separately instead of inverting this palette.
