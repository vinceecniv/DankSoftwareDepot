import QtQuick
import QtQuick.Effects
import qs.Common

// The themed-app-icon effect, in one place because six views draw icons and
// six copies of a tuning decision is six copies to get wrong.
//
// `colorization` maps an icon's own luminance onto the accent colour: the
// lightest parts of the artwork come out as the accent and everything below
// them runs down towards black. That keeps an icon readable as artwork
// rather than flattening it to a silhouette, and it is also why the same
// setting looks like two different features depending on the palette.
//
// With a light accent on a dark surface the mapping works in the icon's
// favour — highlights land bright against a dark card and the shapes carry.
// With a mid-toned accent on a light surface the whole icon sits in a narrow
// band just below the background and reads as a dark blob with no detail in
// it. So the tone is lifted in light mode only: brightness pulls the shadows
// off the floor, contrast puts back the separation that lifting everything
// equally takes away. In dark mode the untouched mapping is already the
// better picture, and lifting it would only wash it out.
//
// The order matters and is not the one you would write down: MultiEffect
// desaturates *after* it colorizes, which is why there is no greyscale pass
// here — asking for one washes the tint straight back out.
// One more asymmetry, found later and by eye: in light mode the colour
// shouted. Not because it is a different accent — it is the same one — but
// because of where the mapping puts it. In dark mode most of an icon lands
// near black and only the highlights come out accented, so the colour arrives
// in small amounts. In light mode the lift above is applied so shapes stay
// readable, and the effect of that is to move most of the icon *up* into the
// accent, so a card ends up carrying a large block of a fully saturated
// colour. The fix is not less lift — the shapes need it — but a quieter
// colour to lift into: the same hue, with the saturation taken down, so the
// amount of colour on screen matches what dark mode arrives at by accident.
MultiEffect {
    readonly property color _softTint: Qt.hsla(Theme.primary.hslHue,
                                               Theme.primary.hslSaturation * 0.55,
                                               Theme.primary.hslLightness,
                                               1.0)

    brightness: Theme.isLightMode ? 0.32 : 0
    // Contrast reads as vividness as much as separation, so it comes down a
    // little with the saturation rather than staying where it was
    contrast: Theme.isLightMode ? 0.16 : 0
    colorization: 1.0
    colorizationColor: Theme.isLightMode ? _softTint : Theme.primary
}
