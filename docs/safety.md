# Safety: user agreement, drive reminder, sensitive places

Design: canvas "Manotu App Design", page **Safety: agreement, drive reminder, sensitive places**
(row 1 = agreement + reminder, row 2 = sensitive places). Server contract: `docs/api.md`,
"Restricted areas". Decided by the owner on 25 Oct 2026.

Everything in parts 1 and 2 is **on the device only** (privacy rule): the agreement version and date, and the
reminder on/off, live in the app's settings store, go into the user's own backup, and are never sent anywhere. No
analytics event or log line records who agreed or who turned the reminder off.

The app's language follows the phone (BM / EN). Copy below is exact; keep both apps word-for-word identical.

## 1. User agreement (once per version)

`SAFETY_AGREEMENT_VERSION = 1`. Stored: `safety.agreedVersion` (int, 0 = never), `safety.agreedAt` (date).

**When:** at app start, after the splash and **before** the location permission prompt, when
`agreedVersion < SAFETY_AGREEMENT_VERSION`. Existing users who upgrade see it once too. Bump the version only when
the terms change in a way that matters to drivers.

**Screen** (full screen, not dismissible by swipe/back except via "Belum setuju"):

| | BM | EN |
|---|---|---|
| Title | Sebelum kita mula | Before we start |
| Lead | Sekejap sahaja. Ini tentang keselamatan anda dan orang lain di jalan. | Just a moment. This is about your safety and everyone else's on the road. |
| 1 | **Manotu alat bantu sahaja.** Peta, laluan dan laporan mungkin salah atau lapuk. Anda yang memandu dan membuat keputusan. | **Manotu is only an aid.** Maps, routes and reports can be wrong or out of date. You drive and you decide. |
| 2 | **Patuhi undang-undang jalan raya.** Papan tanda, lampu isyarat dan polis sentiasa didahulukan, bukan arahan aplikasi. | **Obey the traffic laws.** Road signs, traffic lights and the police always come before the app's directions. |
| 3 | **Pandu hanya bila cergas.** Jangan memandu ketika letih atau mengantuk, atau di bawah pengaruh alkohol, dadah atau ubat yang mengantukkan. | **Drive only when alert.** Don't drive when tired or sleepy, or under the influence of alcohol, drugs or medicine that makes you drowsy. |
| 4 | **Tangan di stereng, bukan di telefon.** Tetapkan destinasi sebelum bergerak, atau minta penumpang. | **Hands on the wheel, not the phone.** Set your destination before you move, or ask a passenger. |
| 5 | **Tanggungjawab anda.** Setakat yang dibenarkan undang-undang, pembangun Manotu tidak bertanggungjawab atas kemalangan, kecederaan, kerosakan atau saman. | **Your responsibility.** To the extent permitted by law, the developer of Manotu is not responsible for accidents, injury, damage or fines. |
| Links | Terma penuh · Privasi | Full terms · Privacy |
| Primary | Saya faham dan setuju | I understand and agree |
| Secondary | Belum setuju | Not now |
| Footer | Disimpan dalam telefon ini sahaja · Versi 1 | Stored on this phone only · Version 1 |

Links: `https://manotu.app/terms/`, `https://manotu.app/privacy/`.

**Not agreed ("Belum setuju"):** the map, search, places and route preview still work. Starting navigation
(route preview "Mula", a planned drive, an event route) opens a sheet instead:

| | BM | EN |
|---|---|---|
| Title | Setuju dahulu untuk mula memandu | Agree first to start driving |
| Body | Anda masih boleh melihat peta, mencari tempat dan membandingkan laluan. Arahan pandu dimulakan hanya selepas anda bersetuju dengan perjanjian keselamatan. | You can still look at the map, find places and compare routes. Turn-by-turn directions start only after you agree to the safety agreement. |
| Primary | Baca dan setuju (opens the agreement; on agree, navigation starts) | Read and agree |
| Secondary | Bukan sekarang | Not now |

**Car screen (Android Auto / CarPlay):** never shows the agreement. Not agreed yet → the car shows
"Buka Manotu di telefon untuk bermula" / "Open Manotu on your phone to start" instead of starting guidance.

## 2. Safety reminder at the start of every drive

Stored: `safety.reminderEnabled` (bool, default true), `safety.reminderDisabledAt` (date).

**When:** each time navigation is **started** (route preview Mula, planned drive, event route), after the agreement
check and before the first instruction. **Not** on resuming a trip that is already running (process restore,
returning to the app, reroute).

- Reminder enabled and speed < 10 km/h (or unknown): show the card over the map (route already drawn behind it).
  Guidance starts only after the button.
- Speed ≥ 10 km/h when Mula is tapped, or the speed rises to ≥ 10 km/h while the card is open: no card (close it).
  Guidance starts at once with a one-line banner for 5 s, with nothing to tap.
- Reminder disabled: nothing at all.
- No voice for the advice; the voice is for directions only.

**Card:**

| | BM | EN |
|---|---|---|
| Title | Pandu dengan selamat | Drive safely |
| Subtitle | Ke {destination} · {duration} | To {destination} · {duration} |
| 1 | Patuhi undang-undang, papan tanda dan polis. | Obey the law, road signs and the police. |
| 2 | Jangan memandu jika mabuk, khayal atau makan ubat yang mengantukkan. | Never drive drunk, high or on drowsy medicine. |
| 3 | Tangan di stereng. Jangan pegang telefon. | Hands on the wheel. Don't hold the phone. |
| 4 | Arahan nampak salah? Ikut keadaan jalan. | Direction looks wrong? Follow the road. |
| 5 (rest) | Letih atau mengantuk? Berhenti dan rehat. | Tired or sleepy? Stop and rest. |
| 5 (route > 2 h, highlighted) | Perjalanan jauh: rehat setiap 2 jam. Letih atau mengantuk? Berhenti. | Long drive: rest every 2 hours. Tired or sleepy? Stop. |
| Checkbox | Jangan tunjuk lagi | Don't show again |
| Button (≥ 64 dp/pt) | Faham, mula pandu | Got it, start driving |
| Toast after "don't show again" | Dimatikan. Hidupkan semula di Tetapan › Keselamatan. | Turned off. Turn it back on in Settings › Safety. |

**Moving banner (5 s):** "Pandu dengan selamat. Patuhi undang-undang jalan raya." / "Drive safely. Obey the traffic laws."

## 3. Settings › Keselamatan (Safety)

| Row | BM | EN |
|---|---|---|
| Switch | Nasihat keselamatan setiap kali mula memandu · (off: "Dimatikan pada {date}") | Safety advice every time you start driving · ("Turned off on {date}") |
| Row | Tunjuk contoh sekarang · Lihat kad nasihat tanpa memulakan perjalanan | Show it now · See the advice card without starting a drive |
| Row | Perjanjian pengguna · Dipersetujui {date} · Versi {n} · [Baca semula] | User agreement · Agreed on {date} · Version {n} · [Read again] |
| Link | Terma penuh di manotu.app | Full terms at manotu.app |
| Info | Tetapan ini dan tarikh persetujuan disimpan dalam telefon anda sahaja, dan ikut sandaran anda sendiri. Manotu tidak menerimanya. | These settings and the date you agreed are stored only on your phone and go into your own backup. Manotu never receives them. |

## 4. Sensitive places (adding places, photos, reviews, reports)

The server is the authority (`docs/api.md`, "Restricted areas"); the apps check first so people get a clear answer
before typing anything.

**Data:** `GET /api/v1/restricted-areas` at start-up and at most daily (ETag; keep the last good copy in a file). On
404/offline with no copy: no client-side check (the server still refuses). Point-in-ring (any ring) or distance to the
nearest ring edge ≤ `blockM` → **blocked**; ≤ `reviewM` → **near**.

**A · Blocked pin** (public place, or moving a pin): a sheet instead of the form.

| | BM | EN |
|---|---|---|
| Title | Tidak boleh dikongsi di sini | Can't be shared here |
| Subtitle | Pin berada dalam kawasan larangan | The pin is in a restricted area |
| Body | Manotu tidak menerima tempat, gambar, ulasan atau butiran di kawasan tentera, keselamatan dan strategik. Mengambil gambar atau melakar kawasan larangan juga satu kesalahan di bawah Akta 298. | Manotu doesn't accept places, photos, reviews or details in military, security and strategic areas. Photographing or sketching a restricted area is also an offence under Act 298. |
| Hint | Kedai atau gerai di luar pagar? Alih pin ke tempat sebenar, di luar kawasan berlorek. | A shop or stall outside the fence? Move the pin to where it really is, outside the shaded area. |
| Primary | Alih pin | Move the pin |
| Secondary | Simpan untuk saya sahaja (private place, stays on the phone) | Save just for me |
| Tertiary | Batal | Cancel |

Private places ("Untuk saya") stay allowed anywhere, photos included, because they never leave the phone.

**B · Near (≤ `reviewM`), public:** a note at the top of the form; the photo button is disabled; the submit
button reads "Hantar untuk semakan" / "Send for review".
"Dekat kawasan larangan · Gambar tidak dibenarkan di sini. Tempat ini akan disemak oleh moderator sebelum orang lain
nampak." / "Near a restricted area · Photos aren't allowed here. A moderator will check this place before others can
see it." Under the photo button: "Gambar dimatikan dalam 300 m dari kawasan larangan." / "Photos are off within
300 m of a restricted area."

**C · Sensitive words** (public name, description, review text; `terms` from the server, whole-word, case- and
accent-insensitive): an inline warning below the field, and the submit button reads "Hantar untuk semakan".
"Butiran keselamatan tidak dibenarkan · Jangan tulis tentang pintu masuk, pengawal, CCTV, pagar atau waktu rondaan,
di mana-mana tempat pun. Buang ayat ini, atau tempat ini akan disemak oleh moderator dahulu. [Buang ayat ini]" /
"Security details aren't allowed · Don't write about entrances, guards, CCTV, fences or patrol times, anywhere. Remove
this sentence, or a moderator will check this place first. [Remove this sentence]". "Buang ayat ini" removes each
sentence that contains a term. After sending: "Disemak dalam 24 jam. Anda dapat notis dalam Peti masuk." /
"Checked within 24 hours. You'll get a note in your Inbox."

**Held items:** `heldForReview: true` (place `status: hidden`) → "Sedang disemak" / "Being checked" in My
contributions.

**Server 422 `restricted_area`** on any write: show the server's `detail` (already localized) in the usual error
style; while driving, a short toast only.

**D · Map:** draw the areas as a grey hatched (or translucent grey) fill with a dashed outline, under labels, from
zoom 12, labelled "Kawasan larangan" / "Restricted area" (no names). Tapping inside shows a sheet: title "Kawasan
larangan"; lines "Tiada ulasan, gambar atau tempat tambahan untuk kawasan ini." / "No reviews, photos or added places
for this area.", "Jangan ambil gambar atau melakar kawasan ini (Akta 298)." / "Don't photograph or sketch this area
(Act 298).", "Laluan Manotu tidak melalui kawasan ini." / "Manotu routes don't go through this area."; button
"Tutup" / "Close". Long-press / select-on-map inside an area: "Tambah tempat" goes to A.

**Road reports inside an area (≤ `blockM`):** not sent; toast "Laporan tidak diterima di kawasan larangan." /
"Reports aren't accepted in restricted areas."

**E · Report reasons:** add "Lokasi sensitif atau keselamatan" / "Sensitive or security location"
(`sensitive_location`) to place, review and photo reports, with the explainer "Kawasan tentera atau strategik, rumah
perlindungan, rumah persendirian, atau butiran seperti pengawal dan CCTV. Disembunyikan serta-merta sementara
disemak." / "A military or strategic site, a shelter, a private home, or details such as guards and CCTV. Hidden at
once while it's checked."
