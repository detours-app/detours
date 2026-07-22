ObjC.import("CoreGraphics");

function dictionaryValue(dictionary, key) {
    const value = dictionary.objectForKey(key);
    return value ? value.js : "";
}

function run() {
    // CoreGraphics window enumeration does not use Apple Events,
    // Accessibility, Screen Recording, or UI automation permissions.
    const onScreenOnly = 1;
    const excludeDesktopElements = 16;
    const windowReference = $.CGWindowListCopyWindowInfo(
        onScreenOnly | excludeDesktopElements,
        0
    );
    const windows = ObjC.castRefToObject(windowReference);
    if (!windows || windows.count === 0) {
        throw new Error("CoreGraphics returned no on-screen windows");
    }

    for (let index = 0; index < windows.count; index += 1) {
        const window = windows.objectAtIndex(index);
        const owner = dictionaryValue(window, "kCGWindowOwnerName");
        const isOnScreen = dictionaryValue(window, "kCGWindowIsOnscreen");
        if (owner !== "UserNotificationCenter" || Number(isOnScreen) !== 1) {
            continue;
        }

        const bounds = window.objectForKey("kCGWindowBounds");
        return [
            "visible_prompt: owner=UserNotificationCenter",
            `window=${dictionaryValue(window, "kCGWindowNumber")}`,
            `layer=${dictionaryValue(window, "kCGWindowLayer")}`,
            `x=${dictionaryValue(bounds, "X")}`,
            `y=${dictionaryValue(bounds, "Y")}`,
            `width=${dictionaryValue(bounds, "Width")}`,
            `height=${dictionaryValue(bounds, "Height")}`
        ].join(" ");
    }

    return "";
}
