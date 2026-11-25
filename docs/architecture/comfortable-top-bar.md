# Comfortable top bar

The Comfortable layout is a top-bar version of the vertical sidebar: one 40pt
row holds what the sidebar holds. It replaced the Chrome-style tab strip, header
row and bookmark bar row that Comfortable used to have.

## The row

`TopBarController` (`Sources/UserInterface/HorizontalBar/TabStrip/`) owns the
row for one Space's page tree and lays it out in an `NSStackView`, from the
leading edge:

| Zone | View | Notes |
| --- | --- | --- |
| Hide Top Bar, back, forward, reload | `TopBarNavigationButtons` | After the window's lights; the sidebar header's Top Buttons settings |
| Spaces | `SpacesStripView` in `TopBarSpacesRowView` | The sidebar's strip, icons or dots per Settings › Spaces, clipped to its Spaces and sliding open to the "+" under the pointer. The strip always draws its "+" here (`alwaysShowsAddButton`): the slot's row-hover state is checked against the sidebar's row, which Comfortable never shows. Hidden with one Space, as in the sidebar |
| Pinned extensions and pinned tabs | `PinnedTabViewController`, `style: .row` | The sidebar's own tiles and live cards (open below); extensions always as tiles here |
| Space pins and folders | `BookmarkBar` | Pills with the sidebar's folder icons. A folder, at any depth, opens in place, its bookmarks beside it in one wash (`BookmarkFolderGroupView`): they are built once, laid out at rest behind a clip, and the clip widens on the zone's clock while they fade in, so nothing is rebuilt or flies in. Overflow goes to the More menu |
| Address field | `TopBarAddressField` | The sidebar's `SideAddressBar` (`isInTopBar`), as wide as the sidebar's (the sidebar width the user set, less its insets): its look and buttons, no extensions. It never publishes where pinned extensions go, though it exists, hidden, in the sidebar layouts |
| Tabs, groups, splits | `TabStrip` | Pills; no pinned zone (pinned tabs are tiles) |
| Mini player | `SidebarMediaPlayerView`, `Surface.Kind.topBar` | Compact transport row only |
| Bottom-bar buttons | `TopBarTrailingButtons` | Fold into one menu, Organize Tabs included, when short of room |

Tabs always come after the address field; the active tab is a selected pill.
A favicon-only tab under the pointer grows to its titled width from its own
leading edge and the tabs after it move along (`TabStripLayoutInput
.hoverExpandedIndex`, animated as `.hoverExpansion`), so it stays under the
pointer while it grows. ⌘L opens the Omnibox centred, as ⌘T does; a click on
the field opens it over the field.

The bar lives in titlebar space. Its empty stretches fall through to the
titlebar, so they move the window and zoom it on a double click. Its controls
don't: AppKit asks the view it hit-tests whether a press there may move the
window, and a double press on one that says yes zooms it. So the Space pins
and folder groups, the pinned tiles' plates and the address field (its text
goes to `SideAddressBar`) claim every press inside them and answer
`mouseDownCanMoveWindow = false` with `acceptsFirstResponder = true`, without
which AppKit ignores the answer (`TabItemView` precedent). The SwiftUI button
hosts answer `false` too.

The row starts 10pt after the window's lights. In full screen the lights live
in the system's titlebar window, shown over the bar on demand, so the row
starts at the window's edge.

## Width ladder

`TopBarWidths.solve` is a pure function of the bar's width and the measured
parts. The tabs absorb every change first; then, in order, folders compress
to their icons (the one under the pointer grows back to its titled width on
the tabs' hover clock, the pills after it moving along), the Space's
bookmarks drop their titles, the trailing buttons fold, the mini player goes
compact. The More menu's overflow is decided on widths at rest, so a folder
grown under the pointer never moves a pill into it. The
Space row and the address field keep their widths. Past that the tab strip
scrolls, keeping the active tab in view. Only a window at its narrowest
(400pt) makes the address field and the pinned tiles give way, rather than
break the row's constraints.

The ladder runs when the bar's width changes, when the tab count, the pinned
tiles, the Space pins or the player change, and when the navigation or
trailing buttons change size (their hosting views report it). Layout passes
that keep the bar's width, such as the row's own animations, don't refit.

## State model

Comfortable uses the sidebar's tab model. Space pins stay bound to their
bookmark tabs, bookmark splits bind, Peek works, and the Omnibox resolves pins
and bookmarks to their bound tabs. `LayoutMode.isTraditional` now only means
"horizontal chrome": no docked sidebar column.

## Theme

The bar's controls (address field, pinned tiles, Space pins, folder washes)
use stronger fills than the sidebar's (`topBarControlFill`,
`topBarControlFillHovered`): the sidebar's 4% wash barely shows on 26–28pt
controls on the bar's glass.

The bar paints nothing while docked. It sits on the shell's page-area backdrop
(`ShellContentHostViewController`), the same frosted, Space-tinted surface as
the sidebar, so the theme editor's transparency and saturation apply to it. In
Comfortable that backdrop runs the palette gradient leading → trailing
(`ColoredVisualEffectView.runsPaletteHorizontally`).

## Hiding (⌘S)

⌘S (the Toggle Sidebar command) hides the bar instead of the sidebar. The
page takes or gives back the bar's room in one step, and the bar, on its
glass, slides out of or into the window on the sidebar toggle's curve: a web
page resized frame by frame doesn't redraw into its new room. The
hidden state is window state, on `ShellSplitViewController` (hosted) or
`MainSplitViewController` (standalone), and new windows start with the last
value (`ForkSettings.topBarHidden`). While hidden, `TopBarRevealController`
slides the bar down over the page as a glass panel (the sidebar's behind-window
material and Space fill) when the pointer rests in the band along the
window's top edge: 120ms at the edge itself (its top 5pt), 350ms lower in the
band. The band is the page's 8pt margin and 12pt of the page (12pt of the
page edge to edge), takes no clicks, and does nothing while a mouse button is held,
so the page's own controls at the top stay usable. The bar stays while the pointer, the Omnibox,
a menu, a popover or a hover card is up (menus are followed from the menu
tracking notifications: they are neither child windows nor popovers). The
page never resizes for a reveal.
The window's lights leave with the bar and come back once it has landed.

## Page outline

The bar's tabs are pills that never meet the page, so the page card has a
plain frame: its own 1pt border, or, while an extension side panel is
docked, one rounded outline around [page card | panel card]. Edge-to-edge
pages have none. Nothing about the tabs feeds the outline, so the tab strip
doesn't notify the page tree when it lays out.
