# bento
`bento` is a screen region and point/window selection tool with formattable output for both X11 and Wayland.

NOTE: The Wayland backend is still experimental and does not work correctly on multiple monitors and probably in other contexts as well, expect bugs/weird behavior

## build
Building requires the [zig](https://ziglang.org) compiler

X11 Dependencies:
- xcb
- xcb-shape
- xcb-cursor

Wayland Dependencies:
- wayland-client
- wayland-protocols
- wayland-cursor
- xkbcommon

To install, run `zig build -p <prefix>` where `<prefix>` is the directory that contains the `bin` folder you want it to install to.

So to install it to the system you could do:
```sh
sudo zig build -p /usr/local
```
and to install it for just the current user you could do:
```sh
zig build -p ~/.local
```

You can disable backends in the build with `-Dx11-backend=false` and `-Dwayland-backend=false`

You may also define a different [build mode](https://ziglang.org/documentation/master/#Build-Mode) using `-Dmode=<mode>`, the default is `ReleaseSmall`

## features
- Define a list of rectangles that can be selected by piping it in, with each line being a new rectangle
    - Format is the same as [slurp](https://github.com/emersion/slurp), `x,y wxh label` (label is optional; format for the rects may change later, it's only like this now for the sake of compatibility)
    - On X11 if you don't pass in rectangles manually, then rectangles will instead be generated from the currently visible windows with labels set to the window ID. This can be disabled with the `--force-no-default-rects` flag

- Multiple selection modes
    - Rectangle: the standard selection mode you'd expect from any region selector
        - Modifier keys change how selection works in various ways:
            - SHIFT: Keeps the selection size constant and instead moves the whole selection region around with your mouse
            - CONTROL: Slow down the cursor to make the selection more precise
            - ALT: Lock the selection to a specific axis (whichever you move in first)
            - Additionally, if you are holding any of these modifiers when starting a selection and hovering a pre-defined rectangle, it will set the initial selection dimensions to that rectangle
    - Point: select a single pixel
    - More to come in the future (line, multi-line, multi-rectangle, whatever else might make sense)

## flags/configuration
### formatting
Done with the `-f`/`--format` flag or environment variables. Available formatting options for each mode:
- Rectangle
    - Environment variable: `BENTO_RECTANGLE_FORMAT`
    - Formatting options:
        - `%x` and `%y`: the x and y position of the top-left corner of the rectangle
        - `%w` and `%h`: the width and height of the rectangle
        - `%l`: the label, if selecting a pre-defined rectangle
- Point
    - Environment variable: `BENTO_POINT_FORMAT`
    - Formatting options:
        - `%x` and `%y`: the x and y position of the top-left corner of the rectangle
        - `%l`: the label, if selecting a pre-defined rectangle
Additionally, escape sequences (e.g. `\n`, `\t`) will work in the format string

### everything else

Selection mode is chosen with `-m`/`--mode`, defaults to rectangle if this flag is not used

You can define how much `CONTROL` slows down the cursor in rectangle selections with `-p`/`--precision`, given as the denominator of a fraction (e.g. `-p 5` would move the cursor at 1/5th of it's normal speed), must be greater than 1

Rectangle selections can be locked into an aspect ratio with `-a`/`--aspect`, e.g. `bento -a 16:9`

Border size can be configured with the `-s`/`--border-size` flag or the `BENTO_BORDER_SIZE` environment variable

Border color (color used for selection rectangle and the currently hovered pre-defined rectangle) can be configured with the `-c`/`--border-color` flag or the `BENTO_BORDER_COLOR` environment variable, the value should be a hex color value, e.g. `bento -c ff0000`,  `bento --border-color "#00ffff"`

Inactive border color (color used for pre-defined rectangles that aren't being hovered over) can be configured with the `-i`/`--inactive-border-color` flag or the `BENTO_INACTIVE_BORDER_COLOR` environment variable

The `--force-no-default-rects` option will disable default pre-defined rectangle generation on X11 when none are manually provided and the `--force-default-rects` will generate them even when you manually provide your own

On X11, if the mouse pointer is already captured by another program, bento will exit silently with an error, but if you use the `--x11-wait` flag, it will instead wait for the cursor to be free then continue running as normal

## todo
### frontend
- [ ] Abstract the code to make plugging in new modes easier
- [ ] Line selection mode
    - click and drag to draw a line between two points
    - how should formatting work? should it print two lines with details for each point, or should there be formatting options for `%x2` and whatnot
        - the former would easily scale for multi-line selection (and a line selection could instead be defined as a multi-point selection, with one line being a two-point selection), the latter would be easier to parse in scripts
- [ ] Rotated rectangle mode
    - should formatting be four pairs of x,y coordinates, or should it be the normal rectangle formatting for what the rectangle would be un-rotated + an angle formatting specifier for the user to apply to those values (whichever would be simpler for cropping a screenshot to a rotated rectangle, research this more)
        - or maybe i could just do both, `%x`, `%y`, `%w`, `%h`, and `%a` alongside `%p1x`, `%p1y`, etc.
- [ ] Mode that *only* lets you select pre-defined rectangles
    - formatting would give you everything rectangle formatting does

### backend
- [ ] provide a way for backends to dynamically update the rectangles they provide, this will allow the X11 backend to fully simulate the behavior of traditional region selection tools that are directly aware of windows
- #### wayland
    - [ ] Multi-monitor support
        - i only have one monitor, which makes this hard to develop properly
    - [ ] More efficient line drawing algorithm
        - not too important, won't really matter until diagonal line rendering is necessary
- #### x11
    - [ ] Don't generate rectangles for windows that are completely covered by other windows

## other less organized notes and plans that may or may not happen
- flag to restrict selections to a specific region ([boox](https://github.com/BanchouBoo/boox) had this, but I think I can't really think of any use case to justify it's existence)
- ability to pass in the starting coordinate for a selection
- stamp mode: you pass in the size of the rectangle then place in somewhere on the screen
- slop flags
    - tolerance seems marginally useful
    - i can't think of a good use case for padding, if this is something you would care about let me know
    - nodrag seems useful as an accessibility option, but accessibility tools might already have similar functionality, if you have knowledge on this please let me know
    - research nodecorations more, i don't have window decorations so i need to find a good environment to test and explore how it works
