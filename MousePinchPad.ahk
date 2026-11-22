#Requires AutoHotkey v2.0 64-bit
#SingleInstance Force
CoordMode "Mouse", "Screen"

; pinch-zoom-touchpad: pinch через віртуальний Precision Touchpad (нове API Windows 11).
; На відміну від pinch-zoom / pinch-zoom-follow тут немає тачскріна:
; Windows бачить саме жест тачпада, тож курсор не ховається, кліків і тапів не буває.

; ===== Налаштування =====
ZOOM_STEP := 1.3    ; у скільки разів зумить 1 клік колеса
SMOOTH_MS := 30     ; м'якість руху, мс (більше = плавніше, але з більшою "інерцією")
FRAME_MS  := 4      ; інтервал між кадрами, мс (справжній тачпад шле кадр приблизно кожні 8 мс)
SLOP      := 150    ; "поріг" розпізнавання жесту, соті мм. Не стартує з першого кліку - збільш, стартує ривком - зменш
HOLD_MS   := 30     ; скільки пальці стоять нерухомо перед тим, як їх прибрати
MOVE_PX   := 15     ; на скільки px треба зсунути курсор, щоб центр зуму переїхав
IDLE_MS   := 1500   ; через скільки мс після зуму прибрати віртуальний тачпад із системи

; Координати пальців на віртуальному тачпаді, у сотих міліметра (тачпад 100 x 60 мм)
PAD_W     := 10000
PAD_H     := 6000
MIN_GAP   := 600    ; мінімальна піввідстань між пальцями
MAX_GAP   := 4900   ; максимальна піввідстань між пальцями
START_IN  := 800    ; стартова піввідстань для зуму +
START_OUT := 4600   ; стартова піввідстань для зуму -

CONTACT := 0x2 | 0x4 | 0x4000   ; INRANGE | INCONTACT | CONFIDENCE: палець на тачпаді
RELEASE := 0x4000               ; CONFIDENCE: палець піднято
EPS     := 0.002                ; "доїхали до цілі" (0.2% зуму)

; ===== Ініціалізація =====
DllCall("winmm\timeBeginPeriod", "UInt", 1)   ; точніший Sleep = рівніші кадри
OnExit(Cleanup)

global dev := 0           ; віртуальний тачпад; існує тільки під час зуму і трохи після

; одразу перевіряємо, що віртуальний тачпад взагалі створюється
if !CreateDevice() {
    MsgBox "Не вдалось створити віртуальний тачпад, помилка " A_LastError
    ExitApp
}
DestroyDevice()

; Зум рахуємо в логарифмах: так однаковий клік колеса дає однакову швидкість зуму,
; хоч пальці близько, хоч далеко.
global ltarget := 0.0     ; куди треба дозумити (накопичується від колеса)
global lmid := 0.0        ; проміжна ступінь згладжування
global lcur := 0.0        ; де ми зараз
global lstart := 0.0      ; lcur на момент, коли поставили пальці
global gbase := 0         ; піввідстань між пальцями на старті жесту
global gap := 0           ; поточна піввідстань між пальцями
global active := false    ; чи "пальці" зараз на тачпаді
global running := false   ; чи працює цикл анімації
global needMove := false  ; курсор відійшов, треба переставити пальці
global ax := 0, ay := 0   ; де був курсор, коли поставили пальці
global lastTime := 0      ; час останнього кадру (dwTime)
global buf := Buffer(152 * 2, 0)   ; 2 x POINTER_TYPE_INFO (x64)

; ===== Хоткеї =====
RButton::Click "Right"                         ; сама права кнопка працює як раніше
RButton & WheelUp::OnWheel(ZOOM_STEP)          ; зум +
RButton & WheelDown::OnWheel(1 / ZOOM_STEP)    ; зум -
RButton & WheelRight::Send "{Volume_Up}"       ; звук +
RButton & WheelLeft::Send "{Volume_Down}"      ; звук -
RButton & MButton::Send "{Media_Play_Pause}"   ; пауза / відтворення
RButton & XButton2::AltTab                     ; вперед по вікнах
RButton & XButton1::ShiftAltTab                ; назад по вікнах
RButton & LButton:: {                          ; коротко: робочий стіл, довго: блокування
    if KeyWait("LButton", "T0.8")              ; відпустив раніше ніж за 0.8 с
        Send "#d"
    else
        DllCall("LockWorkStation")
}

; ===== Логіка =====
; Колесо тільки зсуває ціль. Окремий цикл рухає пальці до цілі через два послідовні
; згладжування: рух плавно розганяється і плавно гальмує, а кліки колеса зливаються в один рух.
OnWheel(f) {
    global
    if active {
        MouseGetPos &mx, &my
        if (Abs(mx - ax) > MOVE_PX || Abs(my - ay) > MOVE_PX)
            needMove := true
    }
    ltarget += Ln(f)
    if !running {
        running := true
        SetTimer DestroyIfIdle, 0     ; зум знову йде - тачпад ще знадобиться
        SetTimer RunLoop, -1
    }
}

RunLoop() {
    global
    prev := Now()
    lastChange := prev
    loop {
        Critical "Off"
        Sleep FRAME_MS          ; тут колесо може додати нову ціль
        Critical "On"

        t := Now()
        dt := t - prev, prev := t
        a := 1 - Exp(-dt / SMOOTH_MS)

        ; пальців немає: ставимо, якщо є що зумити, або завершуємо цикл
        if !active {
            if (Abs(ltarget - lcur) < EPS) {
                lcur := lmid := ltarget
                break
            }
            if !Start(ltarget > lcur ? 1 : -1) {
                lcur := lmid := ltarget
                break
            }
            lastChange := t
            continue
        }

        nmid := lmid + (ltarget - lmid) * a
        ncur := lcur + (nmid - lcur) * a
        ngap := gbase * Exp(ncur - lstart)

        ; Треба переставити пальці: курсор переїхав або пальці дійшли до краю / майже зійшлись.
        ; Трохи стоїмо на місці, знімаємо, а на наступному кроці ставимо заново.
        if (needMove || ngap > MAX_GAP || ngap < MIN_GAP) {
            if (t - lastChange >= HOLD_MS)
                Lift()
            else
                Frame(gap, CONTACT)
            continue
        }

        if (Round(ngap) != Round(gap))
            lastChange := t
        lmid := nmid, lcur := ncur
        if !Frame(ngap, CONTACT) {
            Lift()
            lcur := lmid := ltarget
            break
        }

        ; доїхали, пальці постояли нерухомо, права кнопка відпущена: прибираємо пальці
        if (Abs(ltarget - lcur) < EPS && t - lastChange >= HOLD_MS && !GetKeyState("RButton", "P")) {
            Lift()
            lcur := lmid := ltarget
            break
        }
    }
    running := false
    ; якщо поки виходили з циклу встигли крутнути колесо - запускаємось знову
    if (Abs(ltarget - lcur) >= EPS) {
        running := true
        SetTimer RunLoop, -1
    } else {
        SetTimer DestroyIfIdle, -IDLE_MS
    }
}

; Ставимо пальці. sign: 1 = зум +, -1 = зум -
Start(sign) {
    global
    if !dev && !CreateDevice() {
        ToolTip "Не вдалось створити віртуальний тачпад, помилка " A_LastError
        SetTimer () => ToolTip(), -2000
        return false
    }
    MouseGetPos &ax, &ay
    needMove := false
    lstart := lcur
    base := (sign > 0) ? START_IN : START_OUT
    if !Frame(base, CONTACT)
        return false
    active := true
    ; Windows не віддає зум, поки пальці не зсунуться на певну відстань.
    ; Тому наступним кадром одразу "проскакуємо" цей поріг у потрібний бік,
    ; і вже перший клік колеса дає зум.
    gbase := base + sign * SLOP
    return true
}

Lift() {
    global
    if !active
        return
    if !Frame(gap, RELEASE)
        DestroyDevice()   ; не вдалось підняти пальці - прибираємо тачпад цілком, це теж їх знімає
    active := false
}

Frame(d, flags) {
    global
    ; Час кадру - справжній системний час, який тільки зростає. Не скидаємо його між жестами:
    ; якщо час "повертається назад", Windows може загубити кадр із піднятими пальцями.
    t := Max(lastTime + 1, Round(Now())) & 0xFFFFFFFF
    lastTime := t
    gap := d
    half := Round(d)
    loop 2 {
        off := (A_Index - 1) * 152
        px  := PAD_W // 2 + ((A_Index = 1) ? -half : half)
        NumPut "UInt", 5,           buf, off + 0     ; type = PT_TOUCHPAD
        NumPut "UInt", A_Index - 1, buf, off + 12    ; pointerId
        NumPut "UInt", flags,       buf, off + 20    ; pointerFlags
        NumPut "Int", px, "Int", PAD_H // 2, buf, off + 48   ; ptHimetricLocation
        NumPut "UInt", t,           buf, off + 72    ; dwTime
    }
    if !DllCall("user32\InjectSyntheticPointerInput", "Ptr", dev, "Ptr", buf, "UInt", 2) {
        ToolTip "InjectSyntheticPointerInput: помилка " A_LastError
        SetTimer () => ToolTip(), -2000
        return false
    }
    return true
}

; Віртуальний тачпад, який вміє тільки жести (не рухає курсор і не клікає)
CreateDevice() {
    global
    params := Buffer(40, 0)                ; SYNTHETIC_DEVICE_CREATION_PARAMS
    NumPut "UInt", 5,     params, 0        ; pointerType = PT_TOUCHPAD
    NumPut "UInt", 2,     params, 4        ; maxCount = 2 пальці
    NumPut "UInt", 3,     params, 8        ; feedbackMode = POINTER_FEEDBACK_NONE
    NumPut "Ptr",  0,     params, 16       ; hMonitor = NULL
    NumPut "UInt", PAD_W, params, 24       ; deviceWidth
    NumPut "UInt", PAD_H, params, 28       ; deviceHeight
    NumPut "UInt", 0x3,   params, 32       ; SDCO_PHYSICAL_SIZE | SDCO_TOUCHPAD_GESTURE_ONLY
    dev := DllCall("user32\CreateSyntheticPointerDevice2", "Ptr", params, "Ptr")
    return dev != 0
}

DestroyDevice() {
    global
    if dev {
        DllCall("user32\DestroySyntheticPointerDevice", "Ptr", dev)
        dev := 0
    }
    active := false
}

DestroyIfIdle() {
    global
    if (!running && !active)
        DestroyDevice()
}

; точний час у мілісекундах
Now() {
    static freq := 0
    if !freq
        DllCall("QueryPerformanceFrequency", "Int64*", &freq)
    DllCall("QueryPerformanceCounter", "Int64*", &c := 0)
    return c * 1000 / freq
}

Cleanup(*) {
    Lift()
    DestroyDevice()
    DllCall("winmm\timeEndPeriod", "UInt", 1)
}
