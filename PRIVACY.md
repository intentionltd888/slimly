# Slimly 隱私與權限

## 中文

Slimly 沒有自己的伺服器、沒有帳號、沒有遙測。下面是它實際會做的事，一條一條列。

### 會離開你電腦的
1. **你按「分享…」的檔案。** 做好之後按「分享…」，Slimly 叫出 macOS 的分享選單；送去哪（郵件、訊息、AirDrop…）由你選，之後照那個服務的規則。把做好的檔從 Slimly 拖到別的 app 也一樣，交給那個 app 處理。
2. **你貼的網址（網頁轉 PDF）。** 在「轉檔」貼一個網址，Slimly 會像瀏覽器一樣直接連那個網站，把那一頁畫成 PDF。對方看得到你的 IP，跟你用瀏覽器打開那一頁一樣。每次都用一個空白的瀏覽環境：不登入任何網站、不讀你瀏覽器裡的資料、用完不留 cookie。丟進來的網頁檔（.html）如果引用網路上的圖或字型，也會照網頁的寫法去載入。

除了以上兩項，Slimly 不連任何網路：沒有自動更新、沒有使用分析、沒有當機回報、沒有廣告，也不連我們的伺服器。新版放在公開倉的 Releases，下載新的 DMG 蓋過去就好。

下面這些用到 macOS 內建的功能，一樣在這台 Mac 上做：
- **翻譯、摘要（macOS 26 起）**：用 macOS 在這台 Mac 上執行的模型；摘要要先開 Apple Intelligence。翻譯只用已經下載的語言；還沒下載的，Slimly 會請你到「系統設定 → 一般 → 語言與地區 → 翻譯語言」下載，下載由 macOS 處理，不經過 Slimly。
- **辨識文字、把拍的文件拉正**：用 macOS 的 Vision，在這台做。
- **從 iPhone 輸入（接力相機）**：照片由 macOS 從你的 iPhone 傳到這台，Slimly 不連任何伺服器。

### 留在你電腦上的
- **做好的檔**：預設放在原檔旁邊，檔名多一段說明（例如「（已壓縮）」「（已編輯）」）；設定裡可以改成固定一個資料夾（預設 `~/Downloads/Slimly`）。原檔不覆蓋、不刪除。只有你在設定選了「收進『未壓縮備份』」，原檔才會搬進旁邊的「未壓縮備份」資料夾。
- **監看的資料夾**：只看你加進去的資料夾，預設一個都沒有。Slimly 開著的時候，每秒看一次資料夾的第一層；加進去之前就在的檔不動，新放進去的 PDF、照片、Office 檔寫完 2 秒沒變才壓。壓好的放進那個資料夾裡的「Slimly 已壓縮」，原檔不動；有電子簽章或表單的不壓。關掉視窗 Slimly 還在跑，要停就按暫停，或結束 Slimly。
- **設定與「最近做的」**：存在這台 Mac 的 app 設定裡（`~/Library/Preferences/ltd.intention.slimly.plist`），監看的資料夾清單也在這裡。「最近做的」只留 30 筆（檔名、存到哪、大小、時間），在「設定 → 最近做的」可以清掉。
- **你的簽名與縮寫**：畫好或選好的簽名圖存在 `~/Library/Application Support/Slimly/`，下次直接用。要拿掉，把這個資料夾丟到垃圾桶。
- **暫存**：每一份都在系統暫存夾開自己的工作夾，做完、按停止或結束 Slimly 時收掉。例外：從 iPhone 輸入的照片放在系統暫存夾的 `Slimly-Camera`，目前做完不會自動刪掉。
- **密碼**：打開 PDF 時輸入的密碼只放在記憶體裡，關掉視窗就沒了；不寫進任何檔案，也不存進鑰匙圈。命令列只從終端機問密碼，不接受寫在指令裡的密碼。
- **命令列（`Slimly --cli`）**：每次執行用自己的一份暫時設定，結束就收掉，不改 app 裡的設定和「最近做的」。
- **紀錄檔**：Slimly 不另外寫紀錄檔。安裝、修 Dock 那一格時，會在 macOS 的系統紀錄留一行，只在這台。

### 權限：macOS 會問你的，以及 Slimly 會動到的

| 項目 | 什麼時候 | 為什麼 | 不給或關掉會怎樣 |
|---|---|---|---|
| 檔案與資料夾（依位置，macOS 可能會問） | 第一次讀、存桌面、文件、下載項目、外接或網路磁碟上的檔 | 讀你給的檔，把做好的存在原檔旁邊或你選的資料夾 | 那個位置讀不到或存不進去；Slimly 會講是哪個資料夾，可以改存到「下載項目」裡的 Slimly 資料夾，或自己選一個 |
| 監看的資料夾 | 你在「設定 → 監看資料夾」加了資料夾之後，Slimly 開著時每秒一次 | 新檔放進來就自動壓 | 不加就不看；資料夾不見或沒有權限，畫面會顯示「找不到」「沒有權限」，其他照常 |
| 通知（macOS 會問） | 第一次在 Slimly 不在前面時做完（壓完一批，或工具跑超過 10 秒） | 告訴你好了（顯示檔名或省了多少），點一下在 Finder 顯示 | 沒有通知，其他照常 |
| 自動化：控制 Pages、Keynote、Numbers，或 Microsoft Word、PowerPoint（macOS 會問） | 第一次把 Word、PowerPoint、Excel 檔轉成 PDF | 請那個 app 在這台打開檔案、輸出 PDF、不存檔關掉；原本沒開的會順手關掉 | Word 類的檔改用 macOS 內建排版（版面可能不同），PowerPoint、Excel 檔轉不了；之後可以在「系統設定 → 隱私權與安全性 → 自動化」打開 |
| 從 iPhone 輸入（接力相機） | 你按「檔案 → 從 iPhone 輸入」，或轉檔頁的「或用 iPhone 直接拍」 | 用 iPhone 拍文件，直接變成拉正的 PDF | 不用就不會動；Slimly 不用相機權限 |
| 剪貼簿（讀、寫） | 只在你按 ⌘C、⌘X、⌘V 或「拷貝」時 | 拷貝、貼上頁面上的字和圖 | 不按就不碰；Slimly 不會自己去看剪貼簿 |
| 處理中不讓電腦睡著 | 壓縮、工具在跑的時候 | 做到一半不會斷；螢幕照樣可以關 | 做完自動恢復 |
| 右鍵「服務 → 用 Slimly 壓縮」、拖到 Dock、「打開檔案的應用程式」 | 安裝後由 macOS 列出 | 從 Finder 把檔交給 Slimly | 不需要任何權限；不用就不會動；不會改你的預設 app |
| Dock | 第一次從「應用程式」打開 | 把 Slimly 加進 Dock（改的是 Dock 的設定，Dock 會閃一下）；之後每次打開只檢查那一格有沒有指對，指錯才修 | 自己從 Dock 拿掉就好，不會再加回去 |
| 安裝到「應用程式」 | 從 DMG 直接打開時 | 複製到 `/Applications`，會先問你；舊版丟進垃圾桶（可以還原） | 你自己拖過去 |

Slimly 不會要求：完整磁碟取用、輔助使用、螢幕錄影、麥克風、相機、位置、聯絡人、行事曆、照片圖庫、鑰匙圈。

### 你該知道的
- **做出來的檔帶著 Slimly 的記號。** 壓好的 PDF 會在文件資訊裡記下 Slimly 的版本和等級（例如「2.2.0 Q1」），下次放進來就認得出壓過了；照片、掃描轉成的 PDF，建立程式寫 Slimly。原本的標題、作者照留。
- **註解帶著你的名字。** 在編輯器加的註解、回覆、附加檔案，作者是這台 Mac 的使用者全名；存進 PDF 之後，收到的人看得到。打字簽名預設也填這個名字，可以改。
- **照片的位置預設照留。** 壓照片（還有 Office 檔裡的圖）時，相機和拍攝時間照留；GPS 位置預設也照留。要拿掉，到「設定 → 照片的位置資訊（GPS）」選「拿掉」。
- **可以清掉隱藏資訊。** 編輯器「塗黑與保護」的「清除隱藏資訊」，存檔時可以清掉文件資訊與中繼資料、附件、程式碼與自動動作。註解的作者名字不在清除範圍。
- **加密用的密碼 Slimly 不存。** 忘了就打不開，Slimly 也救不回來。

「不會上傳」是說明，不是文宣。

---

## English

Slimly has no server, no account and no telemetry. Here is everything it actually does.

### What leaves your Mac
1. **Files you send with "Share…".** When a file is done and you press "Share…", Slimly opens the macOS share menu. You choose where it goes (Mail, Messages, AirDrop…), and that service's rules apply from there. Dragging a finished file from Slimly into another app works the same way: that app takes over.
2. **Web addresses you paste (web page to PDF).** If you paste an address into "Convert", Slimly connects straight to that site, like a browser, and turns the page into a PDF. The site sees your IP address, exactly as if you opened the page in a browser. Each time Slimly uses a blank browsing session: it never signs in to any site, never reads anything from your browsers and keeps no cookies afterwards. If a web page file (.html) you add refers to images or fonts on the internet, those load too, as the page asks.

Apart from these two, Slimly makes no network connections: no automatic updates, no analytics, no crash reports, no ads, and nothing sent to us. New versions are posted on the Releases page of the public repository; download the new DMG to update.

These use features built into macOS, and also stay on this Mac:
- **Translate and summarize (macOS 26 and later)**: done by macOS models running on this Mac. Summaries need Apple Intelligence turned on. Translation only uses languages already downloaded; if one is missing, Slimly asks you to download it in System Settings → General → Language & Region → Translation Languages. macOS handles that download, not Slimly.
- **Text recognition and straightening photographed documents**: done on this Mac with macOS Vision.
- **Import from iPhone (Continuity Camera)**: macOS brings the photo over from your iPhone. Slimly connects to no server.

### What stays on your Mac
- **Finished files**: saved next to the original by default, with a note added to the name (such as " (compressed)" or " (edited)"). In Settings you can choose one folder instead (`~/Downloads/Slimly` by default). Originals are never overwritten or deleted. Only if you choose "Move to “Uncompressed Originals”" in Settings is the original moved into an "Uncompressed Originals" folder next to it.
- **Watched folders**: Slimly watches only the folders you add; there are none by default. While Slimly is running it checks the top level of each folder once a second. Files already there when you add the folder are left alone. A new PDF, photo or Office file is compressed once it has stopped changing for 2 seconds, and the result goes into "Slimly Compressed" inside that folder; the original stays as it is. Digitally signed files and files with forms are skipped. Closing the window does not quit Slimly; to stop, press Pause or quit Slimly.
- **Settings and Recent**: kept in the app's local preferences (`~/Library/Preferences/ltd.intention.slimly.plist`), including the list of watched folders. Recent keeps 30 items (file name, where it was saved, sizes, time); clear it in Settings → Recent.
- **Your signature and initials**: the signature image you draw or choose is saved in `~/Library/Application Support/Slimly/` so you can reuse it. To remove it, move that folder to the Trash.
- **Temporary files**: each job gets its own work folder in the system temporary folder, removed when the job finishes, when you press Stop or when you quit Slimly. One exception: photos imported from an iPhone go to `Slimly-Camera` in the system temporary folder and are currently not deleted afterwards.
- **Passwords**: a password you type to open a PDF is kept only in memory and is gone when you close the window. It is never written to a file or stored in the Keychain. The command line asks for passwords in Terminal only and refuses passwords written into the command.
- **Command line (`Slimly --cli`)**: each run uses its own temporary settings, removed when it ends. It doesn't change the app's settings or Recent.
- **Logs**: Slimly keeps no log file of its own. Installing, or fixing its Dock icon, adds one line to the macOS system log on this Mac.

### Permissions: what macOS asks you, and what Slimly touches

| Item | When | Why | If you say no or turn it off |
|---|---|---|---|
| Files and folders (macOS may ask, depending on the location) | The first time Slimly reads or saves files on the Desktop, in Documents, in Downloads, or on external or network drives | Read the files you give it; save results next to the original or in the folder you chose | That location can't be read or written. Slimly tells you which folder, and you can save to the Slimly folder in Downloads or pick another folder instead |
| Watched folders | Once a second while Slimly runs, after you add folders in Settings → Watched folders | Compress new files as soon as they arrive | Add none and nothing is watched. If a folder is missing or not readable, it shows as missing or no permission; everything else works |
| Notifications (macOS asks) | The first time something finishes while Slimly isn't in front (a batch, or a tool that ran over 10 seconds) | Tell you it's done (file name or space saved); click to show the result in Finder | No notifications; everything else works |
| Automation: control Pages, Keynote, Numbers, or Microsoft Word or PowerPoint (macOS asks) | The first time you convert a Word, PowerPoint or Excel file to PDF | Ask that app to open the file on this Mac, export a PDF and close without saving; an app that wasn't running is quit afterwards | Word-type files use the macOS text layout instead (the layout may differ); PowerPoint and Excel files can't be converted. You can allow it later in System Settings → Privacy & Security → Automation |
| Import from iPhone (Continuity Camera) | When you choose File → Import from iPhone, or "Or shoot it with your iPhone" in Convert | Photograph a document with your iPhone and get a straightened PDF | Nothing happens unless you use it; Slimly needs no camera access |
| Clipboard (read and write) | Only when you press ⌘C, ⌘X, ⌘V or "Copy" | Copy and paste text and images on the page | Untouched unless you press them; Slimly never checks the clipboard on its own |
| Keep the Mac awake while working | While compressing or running a tool | A job won't break halfway; the display can still sleep | Returns to normal when done |
| "Compress with Slimly" service, dropping on the Dock icon, "Open With" | Listed by macOS after install | Hand files to Slimly from Finder | Needs no permission; nothing happens unless you use them; your default apps don't change |
| Dock | The first time you open Slimly from Applications | Add Slimly to the Dock (changes the Dock preference; the Dock flickers once). After that, each launch only checks that the icon points to the right app and fixes it if not | Remove it from the Dock; it won't be added back |
| Install to Applications | When opened from the DMG | Copy to `/Applications`, after asking you; the old version goes to the Trash (recoverable) | Drag it there yourself |

Slimly never asks for Full Disk Access, Accessibility, Screen Recording, microphone, camera, location, Contacts, Calendars, Photos library or Keychain access.

### Good to know
- **Files carry a Slimly mark.** A compressed PDF records the Slimly version and level in its document info (for example "2.2.0 Q1") so Slimly recognizes it next time. PDFs made from photos or scans list Slimly as the creator. The original title and author are kept.
- **Comments carry your name.** Comments, replies and file attachments you add in the editor use this Mac's full user name as the author. Once saved in the PDF, anyone who receives it can see it. A typed signature starts with the same name; you can change it.
- **Photo location is kept by default.** When compressing photos (and images inside Office files), camera details and capture time are kept, and so is the GPS location by default. To remove it, go to Settings → Photo location (GPS) → Remove.
- **Hidden information can be removed.** In the editor, Redact & Protect → Remove hidden information can clear metadata, attachments, and scripts and actions when you save. Comment author names are not part of it.
- **Slimly doesn't keep encryption passwords.** If you forget one, the file can't be opened, and Slimly can't recover it.

"Nothing is uploaded" is a description, not a selling point.
