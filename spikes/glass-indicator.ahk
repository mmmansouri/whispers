#Requires AutoHotkey v2.0
#SingleInstance Force
; =====================================================================
; Throwaway spike, not part of Whispers: can a native AutoHotkey window
; look like the "liquid glass" indicator of the design mockups?
;
; Kept as the reference for issue #3 and the measurements behind
; docs/adr/0002-glass-indicator-without-backdrop-blur.md.
;
;   Hold F8   listen; release: transcribing -> pasted -> fades out
;   F7        switch rendering mode
;               1 = per-pixel alpha (GDI+): smooth edges, glow, no blur
;               2 = DWM acrylic blur. Measured: the accent blur fills the
;                   whole window rectangle and ignores SetWindowRgn, on a
;                   layered window and on an ordinary one alike. So the
;                   window is shrunk to the pill and Windows 11 rounds its
;                   corners (DWMWA_WINDOW_CORNER_PREFERENCE) - 8 px at most.
;   F6        cycle the states you cannot reach with F8 (warm-up, error)
;   Esc       quit
;
; Command line, for unattended screenshots:
;   glass-indicator.ahk [mode 1|2] [state listen|warm|trans|done|err]
; =====================================================================

global gMode := 1, gState := "hidden", gW := 220.0, gV := 0.0
global gAlpha := 0.0, gT0 := A_TickCount, gRecT0 := 0, gFrozen := false
global gFirstFrameMs := 0, gDownQpc := 0

; Canvas in logical px. The pill is drawn in the middle, the margin
; holds the glow and the shadow, which mode 2's region cuts away.
global PILL_H := 56, MARGIN := 26, CW := 480, CH := PILL_H + 2 * MARGIN
global WIDTHS := Map("listen", 340, "warm", 400, "trans", 220, "done", 220, "err", 420, "hidden", 200)
global ACCENT := 0x7C5CFF, ACCENT2 := 0x3DD6F5

; ---------------------------------------------------------------- GDI+
DllCall("LoadLibrary", "Str", "gdiplus", "Ptr")
si := Buffer(24, 0), NumPut("UInt", 1, si)
DllCall("gdiplus\GdiplusStartup", "Ptr*", &gTok := 0, "Ptr", si, "Ptr", 0)

global S := A_ScreenDPI / 96
global PW := Round(CW * S), PH := Round(CH * S)

bi := Buffer(40, 0)
NumPut("UInt", 40, bi, 0), NumPut("Int", PW, bi, 4), NumPut("Int", -PH, bi, 8)
NumPut("UShort", 1, bi, 12), NumPut("UShort", 32, bi, 14)
hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
global gMemDC := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")
hbm := DllCall("CreateDIBSection", "Ptr", gMemDC, "Ptr", bi, "UInt", 0, "Ptr*", &bits := 0, "Ptr", 0, "UInt", 0, "Ptr")
DllCall("SelectObject", "Ptr", gMemDC, "Ptr", hbm)
DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
DllCall("gdiplus\GdipCreateFromHDC", "Ptr", gMemDC, "Ptr*", &G := 0)
DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", G, "Int", 4)        ; AntiAlias
DllCall("gdiplus\GdipSetPixelOffsetMode", "Ptr", G, "Int", 4)      ; Half
; ClearType needs an opaque background; on per-pixel alpha it fringes.
DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", G, "Int", 4)    ; AntiAlias

global gFontTitle := MakeFont("Segoe UI Semibold", 14, 0)
global gFontSmall := MakeFont("Segoe UI", 12, 0)
DllCall("gdiplus\GdipCreateStringFormat", "Int", 0x1000, "UShort", 0, "Ptr*", &fmt := 0)
global gFmt := fmt
DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", gFmt, "Int", 1)

; -------------------------------------------------------------- window
; WS_EX_LAYERED | WS_EX_TRANSPARENT (click-through) | WS_EX_NOACTIVATE:
; the indicator must never take the focus away from where the text goes.
global gGui := Gui("-Caption +ToolWindow +AlwaysOnTop -DPIScale +E0x80000 +E0x20 +E0x08000000")
MonitorGetWorkArea(MonitorGetPrimary(), &waL, &waT, &waR, &waB)
global WX := waL + ((waR - waL) - PW) // 2, WY := waB - Round(40 * S) - PH
gGui.Show("NA x" WX " y" WY " w" PW " h" PH)
global HWND := gGui.Hwnd
; Mode 2: not layered, so SetWindowRgn clips both the acrylic and the
; content. Black client pixels have alpha 0, which lets the blur through.
global gGlass := Gui("-Caption +ToolWindow +AlwaysOnTop -DPIScale +E0x08000000")
gGlass.BackColor := "000000"
global GHWND := gGlass.Hwnd

; ----------------------------------------------------------- arguments
loop A_Args.Length {
    if (A_Args[A_Index] = "mode" && A_Index < A_Args.Length)
        gMode := Integer(A_Args[A_Index + 1])
    if (A_Args[A_Index] = "state" && A_Index < A_Args.Length) {
        gFrozen := true
        SetState(A_Args[A_Index + 1])
        gW := WIDTHS[gState]
    }
}
ApplyMode()
SetTimer(Frame, 15)

F8:: {
    global gDownQpc, gRecT0
    if (gState = "listen")
        return
    DllCall("QueryPerformanceCounter", "Int64*", &q := 0)
    gDownQpc := q
    gRecT0 := A_TickCount
    SetState("listen")
}
F8 up:: {
    SetState("trans")
    SetTimer(() => SetState("done"), -1100)
    SetTimer(() => (gState = "done" ? SetState("hidden") : 0), -2900)
}
F7:: {
    global gMode
    gMode := gMode = 1 ? 2 : 1
    ApplyMode()
    ToolTip("Mode " gMode (gMode = 1 ? ": per-pixel, no blur" : ": acrylic blur, region-clipped"), 20, 20)
    SetTimer(() => ToolTip(), -1500)
}
F6:: SetState(gState = "warm" ? "err" : "warm")
Esc:: ExitApp()

SetState(s) {
    global gState
    gState := s
}

ApplyMode() {
    if (gMode = 2) {
        Present(0)
        gGlass.Show("NA x" WX " y" WY " w" PW " h" PH)
        SetAccent(GHWND, 4)
        pref := Buffer(4), NumPut("Int", 2, pref)   ; DWMWCP_ROUND
        DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", GHWND, "UInt", 33, "Ptr", pref, "UInt", 4)
    } else {
        gGlass.Hide()
    }
}

; ACCENT_ENABLE_ACRYLICBLURBEHIND through the undocumented
; SetWindowCompositionAttribute(WCA_ACCENT_POLICY). GradientColor is ABGR.
SetAccent(hwnd, state) {
    accent := Buffer(16, 0)
    NumPut("Int", state, accent, 0)
    NumPut("Int", 2, accent, 4)
    NumPut("UInt", 0x381E1616, accent, 8)
    data := Buffer(A_PtrSize * 3, 0)
    NumPut("Int", 19, data, 0)
    NumPut("Ptr", accent.Ptr, data, A_PtrSize)
    NumPut("UPtr", 16, data, A_PtrSize * 2)
    DllCall("user32\SetWindowCompositionAttribute", "Ptr", hwnd, "Ptr", data)
}

; ---------------------------------------------------------- the frame
Frame() {
    global gW, gV, gAlpha, gFirstFrameMs, gDownQpc
    target := WIDTHS[gState]
    ; Under-damped spring: the slight overshoot is the "liquid" morph.
    gV := gV * 0.72 + (target - gW) * 0.12
    gW += gV
    gAlpha += ((gState = "hidden" ? 0 : 1) - gAlpha) * (gState = "hidden" ? 0.18 : 0.45)
    if (gState = "hidden" && gAlpha < 0.01) {
        gAlpha := 0
        if (gMode = 2)
            gGlass.Hide()
        else
            Present(0)
        return
    }
    t := (A_TickCount - gT0) / 1000.0

    DllCall("gdiplus\GdipGraphicsClear", "Ptr", G, "UInt", 0)
    DllCall("gdiplus\GdipResetWorldTransform", "Ptr", G)
    DllCall("gdiplus\GdipScaleWorldTransform", "Ptr", G, "Float", S, "Float", S, "Int", 0)

    w := Max(gW, PILL_H), x := (CW - w) / 2, y := MARGIN
    lvl := 0.35 + 0.65 * Abs(Sin(t * 3.1) * Sin(t * 1.7 + 1))

    if (gMode = 1) {
        ; drop shadow, then the voice halo, as stacks of faint pills
        loop 8
            FillPill(x - A_Index, y + 6 - A_Index * 0.5, w + 2 * A_Index, PILL_H + A_Index, 0x0A000000)
        if (gState = "listen") {
            a := Round(6 + 8 * lvl)
            loop 10
                FillPill(x - A_Index * 1.8, y - A_Index * 1.2, w + A_Index * 3.6, PILL_H + A_Index * 2.4, (a << 24) | ACCENT)
        } else if (gState = "err") {
            loop 8
                FillPill(x - A_Index * 1.8, y - A_Index * 1.2, w + A_Index * 3.6, PILL_H + A_Index * 2.4, 0x09FF7A45)
        }
    }

    ; glass body: denser without blur behind it, or text would not read
    body := gMode = 1 ? 0xB8181820 : 0x50181820
    FillPill(x, y, w, PILL_H, body)
    p := PillPath(x, y, w, PILL_H)
    DllCall("gdiplus\GdipSetClipPath", "Ptr", G, "Ptr", p, "Int", 0)
    ; specular highlight along the top edge
    rc := RectF(x + 14, y + 1, w - 28, 24)
    DllCall("gdiplus\GdipCreateLineBrushFromRect", "Ptr", rc, "UInt", 0x55FFFFFF, "UInt", 0x00FFFFFF, "Int", 1, "Int", 1, "Ptr*", &br := 0)
    hp := PillPath(x + 14, y + 1, w - 28, 24)
    DllCall("gdiplus\GdipFillPath", "Ptr", G, "Ptr", br, "Ptr", hp)
    DllCall("gdiplus\GdipDeletePath", "Ptr", hp)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)

    Content(x, y, w, t, lvl)

    DllCall("gdiplus\GdipResetClip", "Ptr", G)
    ; hairline rim, brighter on top: the edge of the glass
    StrokePath(p, 0x40FFFFFF, 1)
    DllCall("gdiplus\GdipDeletePath", "Ptr", p)

    if (gMode = 2) {
        rx := Round(x * S), ry := Round(y * S), rw := Round(w * S), rh := Round(PILL_H * S)
        if !DllCall("IsWindowVisible", "Ptr", GHWND)
            gGlass.Show("NA")
        ; SWP_NOACTIVATE | SWP_NOZORDER
        DllCall("SetWindowPos", "Ptr", GHWND, "Ptr", 0, "Int", WX + rx, "Int", WY + ry, "Int", rw, "Int", rh, "UInt", 0x14)
        hdc := DllCall("GetDC", "Ptr", GHWND, "Ptr")
        DllCall("BitBlt", "Ptr", hdc, "Int", 0, "Int", 0, "Int", rw, "Int", rh, "Ptr", gMemDC, "Int", rx, "Int", ry, "UInt", 0x00CC0020)
        DllCall("ReleaseDC", "Ptr", GHWND, "Ptr", hdc)
    } else {
        Present(Round(255 * gAlpha))
    }

    if (gDownQpc) {
        DllCall("QueryPerformanceCounter", "Int64*", &q := 0)
        DllCall("QueryPerformanceFrequency", "Int64*", &f := 0)
        gFirstFrameMs := (q - gDownQpc) * 1000 / f
        gDownQpc := 0
        ToolTip("Mode " gMode " - F8 to first frame on screen: " Format("{:.1f}", gFirstFrameMs) " ms", 20, 20)
        SetTimer(() => ToolTip(), -2500)
    }
}

Content(x, y, w, t, lvl) {
    cx := x + 12 + 17, cy := y + PILL_H / 2
    switch gState {
        case "listen":
            rc := RectF(cx - 17, cy - 17, 34, 34)
            DllCall("gdiplus\GdipCreateLineBrushFromRectWithAngle", "Ptr", rc, "UInt", 0xFF000000 | ACCENT, "UInt", 0xFF000000 | ACCENT2, "Float", Mod(t * 150, 360), "Int", 1, "Int", 0, "Ptr*", &br := 0)
            DllCall("gdiplus\GdipFillEllipse", "Ptr", G, "Ptr", br, "Float", cx - 17, "Float", cy - 17, "Float", 34, "Float", 34)
            DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
            FillEllipse(cx - 14, cy - 14, 28, 28, 0x8C0F0F19)
            MicGlyph(cx, cy)
            ; waveform
            n := 26, bx := x + 58, avail := w - 58 - 58
            step := avail / n
            loop n {
                i := A_Index
                h := 5 + 24 * lvl * (0.35 + 0.65 * Abs(Sin(t * 7 + i * 0.83) * Cos(t * 3.3 + i * 0.37)))
                FillRRect(bx + (i - 1) * step, cy - h / 2, 3, h, 1.5, i & 1 ? 0xFFFFFFFF : 0xFFBDF2FC)
            }
            secs := (A_TickCount - (gRecT0 ? gRecT0 : gT0)) // 1000
            DrawText(Format("{}:{:02}", secs // 60, Mod(secs, 60)), gFontTitle, 0xF2FFFFFF, x + w - 56, y, 40, PILL_H, 2)
        case "warm":
            Spinner(cx, cy, t, ACCENT2)
            DrawText("Waking up the model - keep talking", gFontTitle, 0xFFFFFFFF, x + 56, y + 6, w - 140, 26, 0)
            FillRRect(x + 56, y + 36, w - 140, 4, 2, 0x29FFFFFF)
            FillRRect(x + 56, y + 36, (w - 140) * (0.1 + 0.8 * Mod(t / 6, 1)), 4, 2, 0xFF000000 | ACCENT2)
            DrawText("large-v3", gFontSmall, 0xBFFFFFFF, x + w - 80, y, 64, PILL_H, 2)
        case "trans":
            Spinner(cx, cy, t, ACCENT2)
            a := Round(150 + 105 * (0.5 + 0.5 * Sin(t * 5)))
            DrawText("Transcribing...", gFontTitle, (a << 24) | 0xFFFFFF, x + 56, y, w - 70, PILL_H, 0)
        case "done":
            FillEllipse(cx - 17, cy - 17, 34, 34, 0xFF2FBF8F)
            DllCall("gdiplus\GdipCreatePen1", "UInt", 0xFFFFFFFF, "Float", 3, "Int", 0, "Ptr*", &pen := 0)
            DllCall("gdiplus\GdipSetPenStartCap", "Ptr", pen, "Int", 2)
            DllCall("gdiplus\GdipSetPenEndCap", "Ptr", pen, "Int", 2)
            DllCall("gdiplus\GdipDrawLine", "Ptr", G, "Ptr", pen, "Float", cx - 7, "Float", cy + 0.5, "Float", cx - 2.5, "Float", cy + 5)
            DllCall("gdiplus\GdipDrawLine", "Ptr", G, "Ptr", pen, "Float", cx - 2.5, "Float", cy + 5, "Float", cx + 7, "Float", cy - 4.5)
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
            DrawText("Pasted", gFontTitle, 0xFFFFFFFF, x + 56, y + 7, w - 70, 22, 0)
            DrawText("11 words in 0.4 s", gFontSmall, 0xBFFFFFFF, x + 56, y + 27, w - 70, 20, 0)
        case "err":
            FillEllipse(cx - 17, cy - 17, 34, 34, 0xFFE8590C)
            FillRRect(cx - 1.5, cy - 9, 3, 11, 1.5, 0xFFFFFFFF)
            FillEllipse(cx - 2, cy + 5, 4, 4, 0xFFFFFFFF)
            DrawText("Microphone not found", gFontTitle, 0xFFFFFFFF, x + 56, y + 7, w - 70, 22, 0)
            DrawText("Rode NT-USB was unplugged - click the tray icon", gFontSmall, 0xCCFFFFFF, x + 56, y + 27, w - 70, 20, 0)
    }
}

Present(alpha) {
    pt := Buffer(8), NumPut("Int", WX, "Int", WY, pt)
    sz := Buffer(8), NumPut("Int", PW, "Int", PH, sz)
    src := Buffer(8, 0)
    blend := Buffer(4), NumPut("UChar", 0, "UChar", 0, "UChar", alpha, "UChar", 1, blend)
    DllCall("UpdateLayeredWindow", "Ptr", HWND, "Ptr", 0, "Ptr", pt, "Ptr", sz, "Ptr", gMemDC, "Ptr", src, "UInt", 0, "Ptr", blend, "UInt", 2)
}

; ------------------------------------------------------------ helpers
MakeFont(name, size, style) {
    fam := 0
    if DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", name, "Ptr", 0, "Ptr*", &fam)
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", "Segoe UI", "Ptr", 0, "Ptr*", &fam)
    DllCall("gdiplus\GdipCreateFont", "Ptr", fam, "Float", size, "Int", style, "Int", 2, "Ptr*", &f := 0)
    return f
}

RectF(x, y, w, h) {
    b := Buffer(16)
    NumPut("Float", x, "Float", y, "Float", w, "Float", h, b)
    return b
}

RRectPath(x, y, w, h, r) {
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &p := 0)
    d := Min(2 * r, w, h)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x, "Float", y, "Float", d, "Float", d, "Float", 180, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x + w - d, "Float", y, "Float", d, "Float", d, "Float", 270, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x + w - d, "Float", y + h - d, "Float", d, "Float", d, "Float", 0, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x, "Float", y + h - d, "Float", d, "Float", d, "Float", 90, "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", p)
    return p
}

PillPath(x, y, w, h) => RRectPath(x, y, w, h, h / 2)

FillPath(p, argb) {
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &br := 0)
    DllCall("gdiplus\GdipFillPath", "Ptr", G, "Ptr", br, "Ptr", p)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
}

FillPill(x, y, w, h, argb) {
    p := PillPath(x, y, w, h)
    FillPath(p, argb)
    DllCall("gdiplus\GdipDeletePath", "Ptr", p)
}

FillRRect(x, y, w, h, r, argb) {
    p := RRectPath(x, y, w, h, r)
    FillPath(p, argb)
    DllCall("gdiplus\GdipDeletePath", "Ptr", p)
}

StrokePath(p, argb, width) {
    DllCall("gdiplus\GdipCreatePen1", "UInt", argb, "Float", width, "Int", 0, "Ptr*", &pen := 0)
    DllCall("gdiplus\GdipDrawPath", "Ptr", G, "Ptr", pen, "Ptr", p)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
}

FillEllipse(x, y, w, h, argb) {
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &br := 0)
    DllCall("gdiplus\GdipFillEllipse", "Ptr", G, "Ptr", br, "Float", x, "Float", y, "Float", w, "Float", h)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
}

Spinner(cx, cy, t, rgb) {
    DllCall("gdiplus\GdipCreatePen1", "UInt", 0x2EFFFFFF, "Float", 3, "Int", 0, "Ptr*", &pen := 0)
    DllCall("gdiplus\GdipDrawEllipse", "Ptr", G, "Ptr", pen, "Float", cx - 14, "Float", cy - 14, "Float", 28, "Float", 28)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
    DllCall("gdiplus\GdipCreatePen1", "UInt", 0xFF000000 | rgb, "Float", 3, "Int", 0, "Ptr*", &pen := 0)
    DllCall("gdiplus\GdipSetPenStartCap", "Ptr", pen, "Int", 2)
    DllCall("gdiplus\GdipSetPenEndCap", "Ptr", pen, "Int", 2)
    DllCall("gdiplus\GdipDrawArc", "Ptr", G, "Ptr", pen, "Float", cx - 14, "Float", cy - 14, "Float", 28, "Float", 28, "Float", Mod(t * 400, 360), "Float", 100)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
}

MicGlyph(cx, cy) {
    DllCall("gdiplus\GdipCreatePen1", "UInt", 0xFFFFFFFF, "Float", 1.8, "Int", 0, "Ptr*", &pen := 0)
    DllCall("gdiplus\GdipSetPenStartCap", "Ptr", pen, "Int", 2)
    DllCall("gdiplus\GdipSetPenEndCap", "Ptr", pen, "Int", 2)
    p := RRectPath(cx - 3, cy - 8, 6, 10, 3)
    DllCall("gdiplus\GdipDrawPath", "Ptr", G, "Ptr", pen, "Ptr", p)
    DllCall("gdiplus\GdipDeletePath", "Ptr", p)
    DllCall("gdiplus\GdipDrawArc", "Ptr", G, "Ptr", pen, "Float", cx - 6, "Float", cy - 6, "Float", 12, "Float", 11, "Float", 0, "Float", 180)
    DllCall("gdiplus\GdipDrawLine", "Ptr", G, "Ptr", pen, "Float", cx, "Float", cy + 5, "Float", cx, "Float", cy + 8)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
}

DrawText(str, font, argb, x, y, w, h, align) {
    rc := RectF(x, y, w, h)
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &br := 0)
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", gFmt, "Int", align)
    DllCall("gdiplus\GdipDrawString", "Ptr", G, "WStr", str, "Int", -1, "Ptr", font, "Ptr", rc, "Ptr", gFmt, "Ptr", br)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
}
