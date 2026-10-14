// slimly-mu.js — Slimly 編輯器的 MuPDF 引擎（2.2）。由 app 內的 bin/mutool 執行：mutool run slimly-mu.js <指令> …
// MuJS＝ES5：只能用 var／function，不能用 let、箭頭函式、樣板字串。字串逐字讀很慢（UTF-8 內碼），內容串流一律先轉成位元組陣列。
//
// 指令
//   text  <pdf> <頁>                 這一頁的字（逐行：位置、每個字的框、字型、大小、顏色）＋圖（內容串流裡第幾張、位置）→ 一行 JSON
//   img   <pdf> <頁> <第幾張> <png>  第 k 張圖存成 PNG（畫面上搬移中的圖用）→ JSON {w,h}
//   apply <in> <spec.json> <out>     存檔：搬／刪／換原本的圖 → 刪字（改過的行、塗黑、擦掉）→ 疊上新內容（另一份 PDF 的同一頁）→ 文件資訊、清除隱藏資訊
//   annmeta <pdf>                    每一頁的註解（照 /Annots 的順序）：種類、/NM、回覆誰（/IRT）、附加檔案的名字與大小（PDFKit 讀不到 /IRT）
//   extract <pdf> <頁> <第幾個> <out> 附加檔案註解裡的檔存出來（沒有內容：error empty）
// 座標一律是 MuPDF 的頁面座標＝顯示方向、原點左上、單位點（跟編輯器畫面上的物件同一套）。
// 失敗一律印 {"error": "…"}，app 照著講。

var ARGS = scriptArgs;

function out(o) { print(JSON.stringify(o)); }
function r2(v) { return Math.round(v * 100) / 100; }
function fail(msg) { out({ error: String(msg) }); quit(); }

// ── 矩陣（PDF 慣例：列向量，p' = p × M；M = [a b c d e f]） ──
function mul(A, B) {
  return [A[0] * B[0] + A[1] * B[2], A[0] * B[1] + A[1] * B[3], A[2] * B[0] + A[3] * B[2], A[2] * B[1] + A[3] * B[3],
          A[4] * B[0] + A[5] * B[2] + B[4], A[4] * B[1] + A[5] * B[3] + B[5]];
}
function inv(M) {
  var det = M[0] * M[3] - M[1] * M[2];
  if (Math.abs(det) < 1e-12) return null;
  var a = M[3] / det, b = -M[1] / det, c = -M[2] / det, d = M[0] / det;
  return [a, b, c, d, -(M[4] * a + M[5] * c), -(M[4] * b + M[5] * d)];
}
function tp(M, x, y) { return [x * M[0] + y * M[2] + M[4], x * M[1] + y * M[3] + M[5]]; }
function unitBox(M) {
  var p = [tp(M, 0, 0), tp(M, 1, 0), tp(M, 0, 1), tp(M, 1, 1)], x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
  for (var i = 0; i < 4; i++) { x0 = Math.min(x0, p[i][0]); y0 = Math.min(y0, p[i][1]); x1 = Math.max(x1, p[i][0]); y1 = Math.max(y1, p[i][1]); }
  return [x0, y0, x1, y1];
}
function num6(M) { var s = []; for (var i = 0; i < 6; i++) s.push(String(Math.round(M[i] * 1e6) / 1e6)); return s.join(" "); }
function mat(obj) {
  if (!obj || obj.isNull() || !obj.isArray() || obj.length < 6) return [1, 0, 0, 1, 0, 0];
  var m = []; for (var i = 0; i < 6; i++) m.push(obj.get(i).asNumber()); return m;
}

// ── 內容串流：位元組陣列＋掃描器（只認得要用的：q Q cm Do BI…EI；其他運算子照原樣跳過） ──
function bytes(buf) { var n = buf.getLength(), a = new Array(n); for (var i = 0; i < n; i++) a[i] = buf.readByte(i); return a; }
function isWS(c) { return c === 32 || c === 10 || c === 13 || c === 9 || c === 12 || c === 0; }
function isDL(c) { return c === 40 || c === 41 || c === 60 || c === 62 || c === 91 || c === 93 || c === 123 || c === 125 || c === 47 || c === 37; }
function tok(a, s, e) { var r = ""; for (var i = s; i < e; i++) r += String.fromCharCode(a[i]); return r; }
function nameAt(a, s, e) {                       // /Na#20me → "Na me"
  var r = "";
  for (var i = s + 1; i < e; i++) {
    if (a[i] === 35 && i + 2 < e) { r += String.fromCharCode(parseInt(String.fromCharCode(a[i + 1], a[i + 2]), 16)); i += 2; }
    else r += String.fromCharCode(a[i]);
  }
  return r;
}
function skipStr(a, i) {
  var d = 0, n = a.length;
  while (i < n) { var c = a[i]; if (c === 92) { i += 2; continue; } if (c === 40) d++; else if (c === 41) { d--; if (d === 0) return i + 1; } i++; }
  return n;
}
function skipHex(a, i) { var n = a.length; while (i < n && a[i] !== 62) i++; return i + 1; }
function skipComp(a, i) {                        // [ … ] 或 << … >>（裡面可以有字串、巢狀）
  var n = a.length, depth = 0;
  while (i < n) {
    var c = a[i];
    if (c === 40) { i = skipStr(a, i); continue; }
    if (c === 37) { while (i < n && a[i] !== 10 && a[i] !== 13) i++; continue; }
    if (c === 91) { depth++; i++; continue; }
    if (c === 93) { depth--; i++; if (depth <= 0) return i; continue; }
    if (c === 60) { if (a[i + 1] === 60) { depth++; i += 2; continue; } i = skipHex(a, i); if (depth <= 0) return i; continue; }
    if (c === 62 && a[i + 1] === 62) { depth--; i += 2; if (depth <= 0) return i; continue; }
    i++;
  }
  return n;
}
// cb(op, operands, opStart, opEnd)；operands＝[{t, s, e}]（t：n 名稱、# 數字、s 字串、d 字典／十六進位、a 陣列）
function scan(a, cb) {
  var n = a.length, i = 0, ops = [];
  while (i < n) {
    var c = a[i];
    if (isWS(c)) { i++; continue; }
    if (c === 37) { while (i < n && a[i] !== 10 && a[i] !== 13) i++; continue; }
    var s = i;
    if (c === 47) { i++; while (i < n && !isWS(a[i]) && !isDL(a[i])) i++; ops.push({ t: "n", s: s, e: i }); continue; }
    if (c === 40) { i = skipStr(a, i); ops.push({ t: "s", s: s, e: i }); continue; }
    if (c === 60) { i = (a[i + 1] === 60) ? skipComp(a, i) : skipHex(a, i); ops.push({ t: "d", s: s, e: i }); continue; }
    if (c === 91) { i = skipComp(a, i); ops.push({ t: "a", s: s, e: i }); continue; }
    if (c === 41 || c === 62 || c === 93 || c === 123 || c === 125) { i++; continue; }
    while (i < n && !isWS(a[i]) && !isDL(a[i])) i++;
    var c0 = a[s];
    if ((c0 >= 48 && c0 <= 57) || c0 === 43 || c0 === 45 || c0 === 46) { ops.push({ t: "#", s: s, e: i }); continue; }
    var op = tok(a, s, i);
    if (op === "BI") {                           // 內嵌圖：找 ID，再找前後都是空白的 EI
      var j = i;
      while (j < n - 2 && !(a[j] === 73 && a[j + 1] === 68 && isWS(a[j - 1]) && isWS(a[j + 2]))) j++;
      j += 3;
      while (j < n - 1 && !(a[j] === 69 && a[j + 1] === 73 && isWS(a[j - 1]) && (j + 2 >= n || isWS(a[j + 2]) || isDL(a[j + 2])))) j++;
      i = Math.min(n, j + 2);
      cb("BI", ops, s, i);
      ops = [];
      continue;
    }
    cb(op, ops, s, i);
    ops = [];
  }
}
function numsOf(a, ops, k) { var m = []; for (var i = ops.length - k; i < ops.length; i++) m.push(parseFloat(tok(a, ops[i].s, ops[i].e))); return m; }

function pageContents(pageObj) {
  var c = pageObj.get("Contents"), b = new Buffer();
  if (!c || c.isNull()) return b;
  if (c.isArray()) { for (var i = 0; i < c.length; i++) { var s = c.get(i); if (s.isStream()) { b.writeBuffer(s.readStream()); b.write("\n"); } } }
  else if (c.isStream()) b.writeBuffer(c.readStream());
  return b;
}
function xobj(res, name) {
  if (!res || res.isNull()) return null;
  var X = res.get("XObject");
  if (!X || X.isNull()) return null;
  var o = X.get(name);
  return (o && !o.isNull()) ? o : null;
}
// get() 沒有這個鍵時回 JS 的 null（不是 PDF 的 null 物件）
function gnum(o, k, d) { var v = o.get(k); return (v && v.isNumber()) ? v.asNumber() : d; }
function gbool(o, k) { var v = o.get(k); return !!(v && v.isBoolean() && v.asBoolean()); }
function subtype(o) { var s = o.get("Subtype"); return (s && s.isName()) ? s.asName() : ""; }

// 一個串流（頁面內容或表單）裡的圖：每個 Do／BI 的序號＝xi；表單往裡面找（最多 10 層、不繞圈）
// 回傳 [{path:[xi,…], m:顯示方向的矩陣, inl, name, w, h, form: 最內層是不是在表單裡}]
function walkImages(a, res, ctm, path, list, depth, seen) {
  var stack = [], C = ctm, xi = 0;
  scan(a, function (op, ops, s, e) {
    if (op === "q") stack.push(C);
    else if (op === "Q") { if (stack.length) C = stack.pop(); }
    else if (op === "cm") { if (ops.length >= 6) C = mul(numsOf(a, ops, 6), C); }
    else if (op === "Do") {
      var k = xi++;
      var nt = ops.length ? ops[ops.length - 1] : null;
      if (!nt || nt.t !== "n") return;
      var name = nameAt(a, nt.s, nt.e), xo = xobj(res, name);
      if (!xo) return;
      var st = subtype(xo);
      if (st === "Image") {
        list.push({ path: path.concat([k]), m: C, inl: false, name: name, w: gnum(xo, "Width", 0), h: gnum(xo, "Height", 0), mask: gbool(xo, "ImageMask") });
      } else if (st === "Form" && depth < 10) {
        var id = xo.isIndirect() ? xo.asIndirect() : -1;
        if (id >= 0 && seen.indexOf(id) >= 0) return;
        var fr = xo.get("Resources");
        var sub = bytes(xo.readStream());
        walkImages(sub, (fr && !fr.isNull()) ? fr : res, mul(mat(xo.get("Matrix")), C), path.concat([k]), list, depth + 1, id >= 0 ? seen.concat([id]) : seen);
      }
    } else if (op === "BI") {
      var k2 = xi++;
      list.push({ path: path.concat([k2]), m: C, inl: true, name: "", w: 0, h: 0, mask: false });
    }
  });
}
function pageImages(doc, page) {
  var po = page.getObject(), list = [];
  walkImages(bytes(pageContents(po)), po.getInheritable("Resources"), page.getTransform(), [], list, 0, []);
  var P = page.getBounds();
  var outl = [];
  for (var i = 0; i < list.length; i++) {
    var b = unitBox(list[i].m);
    // 太小（小於 2 點）或整個在頁面外的不列（多半是排版用的隱形圖）
    if (b[2] - b[0] < 2 || b[3] - b[1] < 2 || b[2] < P[0] || b[3] < P[1] || b[0] > P[2] || b[1] > P[3]) { list[i].skip = true; continue; }
    list[i].b = b;
  }
  return list;
}

// ── scan：指定的頁被圖蓋住多少（0–1）。「有 n 頁是掃描的」＝幾乎沒有字、又被圖蓋滿；空白頁、封面、放一張小照片的頁不算 ──
function cmdScan(path, list) {
  var doc = Document.openDocument(path);
  if (doc.needsPassword() && !doc.authenticatePassword(readline() || "")) fail("locked");
  var idx = String(list || "").split(","), res = {};
  for (var n = 0; n < idx.length; n++) {
    if (idx[n] === "") continue;
    var i = parseInt(idx[n], 10); if (!(i >= 0 && i < doc.countPages())) continue;
    var page = doc.loadPage(i), B = page.getBounds(), area = Math.max(1, (B[2] - B[0]) * (B[3] - B[1])), cov = 0, all = [];
    try { all = pageImages(doc, page); } catch (e) {}
    for (var k = 0; k < all.length; k++) {
      if (all[k].skip) continue;
      var b = all[k].b;
      cov += Math.max(0, Math.min(b[2], B[2]) - Math.max(b[0], B[0])) * Math.max(0, Math.min(b[3], B[3]) - Math.max(b[1], B[1]));
    }
    res[i] = Math.min(1, cov / area);
  }
  out({ cover: res });
}

// ── text：逐行的字 ──
function hexColor(c) {
  if (!c || c.length < 3) return "#000000";
  var k = (c[0] > 1 || c[1] > 1 || c[2] > 1) ? 1 : 255, s = "#";
  for (var i = 0; i < 3; i++) { var v = Math.max(0, Math.min(255, Math.round(c[i] * k))); s += (v < 16 ? "0" : "") + v.toString(16).toUpperCase(); }
  return s;
}
function cmdText(path, pi) {
  var doc = Document.openDocument(path);
  if (doc.needsPassword()) fail("locked");
  var page = doc.loadPage(pi), P = page.getBounds();
  var st = page.toStructuredText("preserve-whitespace");
  var lines = [], L = null, blk = -1, run = null;
  st.walk({
    beginTextBlock: function (b) { blk++; },
    beginLine: function (b, wmode, dir) {
      L = { b: [r2(b[0]), r2(b[1]), r2(b[2]), r2(b[3])], dir: [r2(dir[0]), r2(dir[1])], wm: wmode ? 1 : 0, blk: blk, ch: [], q: [], o: null, runs: [] };
      run = null;
    },
    onChar: function (c, origin, font, size, quad, color) {
      if (!L) return;
      if (L.o === null) L.o = [r2(origin[0]), r2(origin[1])];
      var name = font.getName().replace(/^[A-Z]{6}\+/, "");
      var fl = (font.isBold() ? 1 : 0) | (font.isItalic() ? 2 : 0) | (font.isSerif() ? 4 : 0) | (font.isMono() ? 8 : 0);
      var col = hexColor(color), sz = r2(size);
      if (!run || run.f !== name || run.s !== sz || run.c !== col || run.fl !== fl) { run = { i: L.ch.length, f: name, s: sz, c: col, fl: fl }; L.runs.push(run); }
      L.ch.push(c);                                  // 一個字一格（字串長度各家算法不同：MuJS、Swift、瀏覽器；用陣列就不會對不上）
      var x0 = Math.min(quad[0], quad[4]), x1 = Math.max(quad[2], quad[6]), y0 = Math.min(quad[1], quad[3]), y1 = Math.max(quad[5], quad[7]);
      L.q.push(r2(x0), r2(y0), r2(x1), r2(y1));
    },
    endLine: function () { if (L && L.ch.length) lines.push(L); L = null; },
    endTextBlock: function () {}
  });
  // 看不見的字（掃描檔上的辨識文字層）：整頁的字都是模式 3 → 改字時要蓋一塊底色
  var tr = 0, vis = 0, invs = 0, stk = [];
  function cnt() { if (tr === 3 || tr === 7) invs++; else vis++; }
  try { page.process({ op_q: function () { stk.push(tr); }, op_Q: function () { if (stk.length) tr = stk.pop(); }, op_Tr: function (m) { tr = m; }, op_Tj: cnt, op_TJ: cnt, op_squote: cnt, op_dquote: cnt }); } catch (e) {}
  var imgs = [], all = [];
  try { all = pageImages(doc, page); } catch (e) {}
  for (var i = 0; i < all.length; i++) {
    if (all[i].skip) continue;
    var m = all[i].m, b = all[i].b;
    imgs.push({ k: i, b: [r2(b[0]), r2(b[1]), r2(b[2]), r2(b[3])], m: [r2(m[0]), r2(m[1]), r2(m[2]), r2(m[3]), r2(m[4]), r2(m[5])], w: all[i].w, h: all[i].h, inl: all[i].inl, form: all[i].path.length > 1, mask: all[i].mask });
  }
  out({ w: r2(P[2] - P[0]), h: r2(P[3] - P[1]), inv: invs > 0 && vis === 0, lines: lines, imgs: imgs });
}

// ── img：第 k 張圖的像素（畫面顯示用） ──
function cmdImg(path, pi, k, png) {
  var doc = Document.openDocument(path);
  var page = doc.loadPage(pi), all = pageImages(doc, page), it = all[k];
  if (!it) fail("no image " + k);
  var po = page.getObject(), stepObj = null;
  if (!it.inl) {
    // 沿著路徑找到那個 XObject
    var res = po.getInheritable("Resources"), a = bytes(pageContents(po));
    for (var d = 0; d < it.path.length; d++) {
      var want = it.path[d], found = null, xi = 0;
      scan(a, function (op, ops) { if (op === "Do" || op === "BI") { if (xi === want && op === "Do" && ops.length && ops[ops.length - 1].t === "n") found = nameAt(a, ops[ops.length - 1].s, ops[ops.length - 1].e); xi++; } });
      if (found === null) break;
      var xo = xobj(res, found);
      if (!xo) break;
      if (d === it.path.length - 1) { stepObj = xo; break; }
      var fr = xo.get("Resources"); if (fr && !fr.isNull()) res = fr;
      a = bytes(xo.readStream());
    }
  }
  var W, H, pm;
  if (stepObj) {
    // 圖單獨放在一張透明的頁上，用 MuPDF 完整的畫法畫（軟遮罩、色彩描述檔都算進去；直接畫 Image 會把透明的地方畫成黑）
    W = gnum(stepObj, "Width", 1); H = gnum(stepObj, "Height", 1);
    var sc = Math.min(1, 2400 / Math.max(W, H)); W = Math.max(1, Math.round(W * sc)); H = Math.max(1, Math.round(H * sc));
    var tmp = new PDFDocument();
    var xo = tmp.newDictionary(); xo.put("Im0", tmp.graftObject(stepObj));
    var res = tmp.newDictionary(); res.put("XObject", xo);
    var body = new Buffer(); body.write("q " + W + " 0 0 " + H + " 0 0 cm /Im0 Do Q");
    tmp.insertPage(-1, tmp.addPage([0, 0, W, H], 0, res, body));
    pm = tmp.loadPage(0).toPixmap(Matrix.identity, ColorSpace.DeviceRGB, true, false);
  } else {
    // 內嵌圖：畫那一塊頁面（只給畫面看）
    var b = it.b || unitBox(it.m), s2 = Math.min(4, 2400 / Math.max(1, b[2] - b[0], b[3] - b[1]));
    W = Math.max(1, Math.round((b[2] - b[0]) * s2)); H = Math.max(1, Math.round((b[3] - b[1]) * s2));
    pm = page.toPixmap([s2, 0, 0, s2, -b[0] * s2, -b[1] * s2], ColorSpace.DeviceRGB, true, false);
  }
  pm.saveAsPNG(png);
  out({ w: W, h: H, raw: !stepObj });
}

// ── apply：存檔 ──
function ownResources(doc, pageObj) {
  var R = pageObj.get("Resources");
  if (R && !R.isNull()) return R;
  var inh = pageObj.getInheritable("Resources"), n = doc.newDictionary();
  if (inh && !inh.isNull()) inh.forEach(function (v, k) { n.put(k, v); });
  pageObj.put("Resources", n);
  return pageObj.get("Resources");
}
function xdict(doc, res) {
  var X = res.get("XObject");
  if (!X || X.isNull()) { res.put("XObject", doc.newDictionary()); X = res.get("XObject"); }
  return X;
}
var SEQ = 0;
function uname(prefix) { SEQ++; return prefix + SEQ + "x" + Math.floor(Math.random() * 1e6).toString(36); }

// 原本的圖：搬、刪、換。改內容串流裡那一個 Do（在表單裡的：沿路複製一份表單，只改這一頁用的那份）
function imageOps(doc, pi, ops) {
  var page = doc.loadPage(pi), po = page.getObject();
  var all = pageImages(doc, page);
  // 編輯器看到的第 k 張 → 這裡的第 k 張；位置對不上就找位置最接近的那張
  var root = { edits: {}, kids: {} };
  for (var i = 0; i < ops.length; i++) {
    var o = ops[i], it = all[o.k];
    if (o.b && (!it || !it.b || Math.abs(it.b[0] - o.b[0]) + Math.abs(it.b[1] - o.b[1]) + Math.abs(it.b[2] - o.b[2]) + Math.abs(it.b[3] - o.b[3]) > 4)) {
      var best = null, bd = 1e9;
      for (var j = 0; j < all.length; j++) {
        if (!all[j].b) continue;
        var dd = Math.abs(all[j].b[0] - o.b[0]) + Math.abs(all[j].b[1] - o.b[1]) + Math.abs(all[j].b[2] - o.b[2]) + Math.abs(all[j].b[3] - o.b[3]);
        if (dd < bd) { bd = dd; best = all[j]; }
      }
      if (!best || bd > 8) fail("image " + o.k + " moved");
      it = best;
    }
    if (!it) fail("no image " + o.k);
    var node = root;
    for (var d = 0; d < it.path.length - 1; d++) {
      var st = it.path[d];
      if (!node.kids[st]) node.kids[st] = { edits: {}, kids: {} };
      node = node.kids[st];
    }
    node.edits[it.path[it.path.length - 1]] = { op: o, occ: it };
  }
  var res = ownResources(doc, po);
  var nb = patchStream(doc, pageContents(po), res, root);
  po.put("Contents", doc.addStream(nb, {}));
}
function patchStream(doc, buf, res, node) {
  var a = bytes(buf), edits = [], xi = 0;
  scan(a, function (op, ops, s, e) {
    if (op !== "Do" && op !== "BI") return;
    var k = xi++;
    var nt = (op === "Do" && ops.length && ops[ops.length - 1].t === "n") ? ops[ops.length - 1] : null;
    var start = nt ? nt.s : s;
    if (node.kids[k] && nt) {
      var name = nameAt(a, nt.s, nt.e), xo = xobj(res, name);
      if (xo && subtype(xo) === "Form") {
        var fr = xo.get("Resources");
        var sub = patchStream(doc, xo.readStream(), (fr && !fr.isNull()) ? fr : res, node.kids[k]);
        var nd = doc.newDictionary();
        xo.forEach(function (v, key) { if (["Length", "Filter", "DecodeParms", "DL"].indexOf(key) < 0) nd.put(key, v); });
        var clone = doc.addStream(sub, nd), nn = uname("SlF");
        xdict(doc, res).put(nn, clone);
        edits.push({ s: nt.s, e: nt.e, r: "/" + nn });
      }
    }
    var ed = node.edits[k];
    if (!ed) return;
    var o = ed.op, C = ed.occ.m, body = tok(a, start, e);
    if (o.op === "del") { edits.push({ s: start, e: e, r: " " }); return; }
    if (o.op === "rep") {
      var img = new Image(o.file), ref = doc.addImage(img), nn2 = uname("SlI");
      xdict(doc, res).put(nn2, ref);
      body = "/" + nn2 + " Do";
    }
    var T = o.T || [1, 0, 0, 1, 0, 0], Ci = inv(C);
    if (!Ci) return;
    var X = mul(mul(C, T), Ci);
    edits.push({ s: start, e: e, r: "q " + num6(X) + " cm " + body + " Q" });
  });
  if (!edits.length) return buf;
  edits.sort(function (x, y) { return x.s - y.s; });
  var nb = new Buffer(), pos = 0;
  for (var i = 0; i < edits.length; i++) {
    if (edits[i].s < pos) continue;
    if (edits[i].s > pos) nb.writeBuffer(buf.slice(pos, edits[i].s));
    nb.write(edits[i].r);
    pos = edits[i].e;
  }
  if (pos < buf.getLength()) nb.writeBuffer(buf.slice(pos, buf.getLength()));
  return nb;
}

// 刪字／刪內容：一批框一次做。protect＝先把這頁的連結、註解拿開（改字、擦掉不該順便刪掉它們；真的塗黑才讓 MuPDF 一起清）
function redactPass(doc, pi, rects, imageMethod, lineArt, protect) {
  if (!rects || !rects.length) return;
  var page = doc.loadPage(pi), po = page.getObject();
  var saved = null, held = [];
  var A = po.get("Annots");
  if (A && !A.isNull() && A.isArray()) {
    // 原本就在的「待塗黑」標記（別的軟體留的）不要被這次順便套用
    for (var i = 0; i < A.length; i++) {
      var an = A.get(i);
      if (subtype(an) === "Redact") { an.put("Subtype", doc.newName("SlimlyRedactHold")); held.push(an); }
    }
    if (protect) {
      saved = doc.newArray();
      for (var j = 0; j < A.length; j++) saved.push(A.get(j));
      po.put("Annots", doc.newArray());
    }
  }
  var r = page.createAnnotation("Redact");
  for (var k = 0; k < rects.length; k++) {
    var q = rects[k];
    if (q[2] - q[0] <= 0 || q[3] - q[1] <= 0) continue;
    r.addQuadPoint([q[0], q[1], q[2], q[1], q[0], q[3], q[2], q[3]]);
  }
  page.applyRedactions(false, imageMethod, lineArt, 0);
  if (saved) po.put("Annots", saved);
  for (var h = 0; h < held.length; h++) held[h].put("Subtype", doc.newName("Redact"));
}

// 疊一頁（新加的字、圖、簽名、頁碼、浮水印…）：另一份 PDF 的一頁 → 表單 XObject → 畫在原頁內容的上面（或下面＝背景）
function stamp(doc, pi, src, si, gm, under) {
  var page = doc.loadPage(pi), po = page.getObject();
  var sp = src.findPage(si);
  var d = doc.newDictionary();
  d.put("Type", doc.newName("XObject")); d.put("Subtype", doc.newName("Form"));
  d.put("BBox", gm.graftObject(sp.getInheritable("MediaBox")));
  var sr = sp.getInheritable("Resources");
  if (sr && !sr.isNull()) d.put("Resources", gm.graftObject(sr));
  var xo = doc.addStream(pageContents(sp), d);
  var nn = uname(under ? "SlBg" : "SlOv");
  xdict(doc, ownResources(doc, po)).put(nn, xo);
  var pre = new Buffer(), post = new Buffer();
  if (under) { pre.write("q /" + nn + " Do Q\nq\n"); post.write("\nQ\n"); }
  else { pre.write("q\n"); post.write("\nQ\nq /" + nn + " Do Q\n"); }
  var C = po.get("Contents"), arr = doc.newArray();
  arr.push(doc.addStream(pre, {}));
  if (C && !C.isNull()) { if (C.isArray()) { for (var i = 0; i < C.length; i++) arr.push(C.get(i)); } else arr.push(C); }
  arr.push(doc.addStream(post, {}));
  po.put("Contents", arr);
}

// 清除隱藏資訊：文件資訊、XMP、附件、JavaScript／啟動外部程式的動作、縮圖、各軟體的私有資料
function sanitize(doc, opt) {
  var tr = doc.getTrailer(), root = tr.get("Root");
  if (opt.meta) {
    tr.put("Info", doc.addObject(doc.newDictionary()));
    root.delete("Metadata"); root.delete("PieceInfo");
  }
  var names = root.get("Names");
  if (names && !names.isNull()) { if (opt.files) names.delete("EmbeddedFiles"); if (opt.js) names.delete("JavaScript"); }
  if (opt.js) {
    root.delete("AA");
    var oa = root.get("OpenAction");
    if (oa && !oa.isNull() && oa.isDictionary()) { var s = oa.get("S"); if (s && s.isName() && ["JavaScript", "Launch", "SubmitForm", "ImportData"].indexOf(s.asName()) >= 0) root.delete("OpenAction"); }
    var af = root.get("AcroForm"); if (af && !af.isNull()) af.delete("XFA");
  }
  var n = doc.countPages();
  for (var i = 0; i < n; i++) {
    var po = doc.findPage(i);
    if (opt.meta) { po.delete("PieceInfo"); po.delete("Thumb"); po.delete("Metadata"); }
    if (opt.js) po.delete("AA");
    var A = po.get("Annots");
    if (!A || A.isNull() || !A.isArray()) continue;
    var keep = doc.newArray(), changed = false;
    for (var j = 0; j < A.length; j++) {
      var an = A.get(j), st = subtype(an);
      if (opt.files && st === "FileAttachment") { changed = true; continue; }
      if (opt.js) {
        an.delete("AA");
        var ac = an.get("A");
        if (ac && !ac.isNull() && ac.isDictionary()) { var sa = ac.get("S"); if (sa && sa.isName() && ["JavaScript", "Launch", "SubmitForm", "ImportData"].indexOf(sa.asName()) >= 0) an.delete("A"); }
      }
      keep.push(an);
    }
    if (changed) po.put("Annots", keep);
  }
}


// 表單欄位（新的）：自己寫欄位物件（PDFKit 寫的沒有 /AcroForm，Acrobat 不當成欄位；選項按鈕的值也會亂碼）
function acroForm(doc) {
  var root = doc.getTrailer().get("Root");
  var af = root.get("AcroForm");
  if (!af || af.isNull()) { root.put("AcroForm", doc.addObject(doc.newDictionary())); af = root.get("AcroForm"); }
  var F = af.get("Fields"); if (!F || F.isNull()) { af.put("Fields", doc.newArray()); }
  var dr = af.get("DR"); if (!dr || dr.isNull()) { af.put("DR", doc.newDictionary()); dr = af.get("DR"); }
  var fonts = dr.get("Font"); if (!fonts || fonts.isNull()) { dr.put("Font", doc.newDictionary()); fonts = dr.get("Font"); }
  if (!fonts.get("Helv")) fonts.put("Helv", doc.addObject({ Type: "Font", Subtype: "Type1", BaseFont: "Helvetica", Encoding: "WinAnsiEncoding" }));
  if (!fonts.get("ZaDb")) fonts.put("ZaDb", doc.addObject({ Type: "Font", Subtype: "Type1", BaseFont: "ZapfDingbats" }));
  if (!fonts.get("SlCJK")) { try { fonts.put("SlCJK", doc.addCJKFont(new Font("zh-Hant"), "zh-Hant", 0, false)); } catch (e) {} }
  if (!af.get("DA")) af.put("DA", doc.newString("/Helv 0 Tf 0 g"));
  af.put("NeedAppearances", true);
  return af;
}
function apStream(doc, w, h, body, zadb) {
  var d = doc.newDictionary();
  d.put("Type", doc.newName("XObject")); d.put("Subtype", doc.newName("Form")); d.put("BBox", [0, 0, w, h]);
  if (zadb) { var r = doc.newDictionary(), f = doc.newDictionary(); f.put("ZaDb", zadb); r.put("Font", f); d.put("Resources", r); }
  var b = new Buffer(); b.write(body);
  return doc.addStream(b, d);
}
function addFields(doc, pi, list) {
  if (!list || !list.length) return;
  var page = doc.loadPage(pi), po = page.getObject(), iv = inv(page.getTransform());
  var af = acroForm(doc), F = af.get("Fields"), zadb = af.get("DR").get("Font").get("ZaDb");
  var hasCJK = !!af.get("DR").get("Font").get("SlCJK");
  var A = po.get("Annots"); if (!A || A.isNull()) { po.put("Annots", doc.newArray()); A = po.get("Annots"); }
  var groups = {};
  for (var i = 0; i < list.length; i++) {
    var f = list[i], r = f.r;
    var p0 = tp(iv, r[0], r[1]), p1 = tp(iv, r[2], r[3]);
    var rect = [Math.min(p0[0], p1[0]), Math.min(p0[1], p1[1]), Math.max(p0[0], p1[0]), Math.max(p0[1], p1[1])];
    var w = rect[2] - rect[0], h = rect[3] - rect[1];
    var wd = doc.newDictionary();
    wd.put("Type", doc.newName("Annot")); wd.put("Subtype", doc.newName("Widget")); wd.put("Rect", rect); wd.put("F", 4); wd.put("P", po);
    var mk = doc.newDictionary(); mk.put("BC", [0.55, 0.57, 0.6]); mk.put("BG", [1, 1, 1]); wd.put("MK", mk);
    var bs = doc.newDictionary(); bs.put("W", 1); bs.put("S", doc.newName("S")); wd.put("BS", bs);
    var fs = f.fs || 11, da = doc.newString((hasCJK ? "/SlCJK " : "/Helv ") + fs + " Tf 0 g");
    var flags = f.req ? 2 : 0;
    if (f.ft === "text") {
      wd.put("FT", doc.newName("Tx")); wd.put("T", doc.newString(f.name)); wd.put("DA", da);
      if (f.multi) flags |= 4096;
      wd.put("Ff", flags);
      if (f.val) wd.put("V", doc.newString(f.val));                // 空字串不寫（加密後 AES 會是空的一塊，預覽程式讀了會報錯）
    } else if (f.ft === "choice") {
      wd.put("FT", doc.newName("Ch")); wd.put("T", doc.newString(f.name)); wd.put("DA", da); wd.put("Ff", flags | 131072);
      var opt = doc.newArray(); for (var k = 0; k < (f.opts || []).length; k++) opt.push(doc.newString(f.opts[k]));
      wd.put("Opt", opt);
      if (f.val || (f.opts || [])[0]) wd.put("V", doc.newString(f.val || f.opts[0]));
    } else if (f.ft === "check" || f.ft === "radio") {
      var on = f.ft === "check" ? "Yes" : String(f.ev || "Choice1").replace(/[^A-Za-z0-9_.-]/g, "_");
      var box = f.ft === "check"
        ? "q 1 g 0 0 " + w + " " + h + " re f 0.55 0.57 0.6 RG 1 w 0.5 0.5 " + (w - 1) + " " + (h - 1) + " re S Q\n"
        : "q 1 g " + circle(w / 2, h / 2, Math.min(w, h) / 2 - 0.5) + " f 0.55 0.57 0.6 RG 1 w " + circle(w / 2, h / 2, Math.min(w, h) / 2 - 0.5) + " S Q\n";
      var mark = f.ft === "check"
        ? "q 0 g BT /ZaDb " + (Math.min(w, h) * 0.8).toFixed(2) + " Tf " + (w * 0.14).toFixed(2) + " " + (h * 0.2).toFixed(2) + " Td (4) Tj ET Q\n"
        : "q 0 g " + circle(w / 2, h / 2, Math.min(w, h) * 0.25) + " f Q\n";
      var N = doc.newDictionary(); N.put(on, apStream(doc, w, h, box + mark, zadb)); N.put("Off", apStream(doc, w, h, box, null));
      var AP = doc.newDictionary(); AP.put("N", N); wd.put("AP", AP); wd.put("AS", doc.newName("Off"));
      mk.put("CA", doc.newString(f.ft === "check" ? "4" : "l")); wd.put("DA", doc.newString("/ZaDb 0 Tf 0 g"));
      if (f.ft === "check") { wd.put("FT", doc.newName("Btn")); wd.put("T", doc.newString(f.name)); wd.put("Ff", flags); wd.put("V", doc.newName("Off")); }
      else {
        var g = groups[f.name];
        if (!g) {
          var gd = doc.newDictionary(); gd.put("FT", doc.newName("Btn")); gd.put("T", doc.newString(f.name)); gd.put("Ff", flags | 49152); gd.put("V", doc.newName("Off")); gd.put("Kids", doc.newArray());
          g = groups[f.name] = doc.addObject(gd); F.push(g);
        }
        wd.put("Parent", g);
      }
    } else if (f.ft === "sig") {
      wd.put("FT", doc.newName("Sig")); wd.put("T", doc.newString(f.name));
      af.put("SigFlags", 1);
    }
    var ref = doc.addObject(wd);
    A.push(ref);
    if (f.ft === "radio") groups[f.name].get("Kids").push(ref); else F.push(ref);
  }
}
function circle(cx, cy, r) {                       // 四段貝茲的圓
  var k = 0.5523 * r, f = function (v) { return v.toFixed(2); };
  return f(cx + r) + " " + f(cy) + " m " + f(cx + r) + " " + f(cy + k) + " " + f(cx + k) + " " + f(cy + r) + " " + f(cx) + " " + f(cy + r) + " c "
    + f(cx - k) + " " + f(cy + r) + " " + f(cx - r) + " " + f(cy + k) + " " + f(cx - r) + " " + f(cy) + " c "
    + f(cx - r) + " " + f(cy - k) + " " + f(cx - k) + " " + f(cy - r) + " " + f(cx) + " " + f(cy - r) + " c "
    + f(cx + k) + " " + f(cy - r) + " " + f(cx + r) + " " + f(cy - k) + " " + f(cx + r) + " " + f(cy) + " c";
}


// 書籤：整棵換掉（PDFKit 寫的書籤樹會少 Parent、Last 指錯；用 MuPDF 的 outline 介面寫）
function setOutline(doc, items) {
  var it = doc.outlineIterator();
  while (it.item()) it.delete();
  function add(list) {
    for (var i = 0; i < list.length; i++) {
      var o = list[i], kids = o.kids || [];
      var uri = (o.page >= 0) ? doc.formatLinkURI({ chapter: 0, page: o.page, type: "XYZ", x: 0, y: o.y || 0, zoom: 0 }) : "";
      it.insert({ title: String(o.title || ""), uri: uri, open: !!(kids.length && o.open) });
      if (kids.length) { it.prev(); it.down(); add(kids); it.up(); it.next(); }
    }
  }
  add(items || []);
}
// Slimly 自己的註解（印章）：PDFKit 不寫 /NM，先把標記放在 /Subj，這裡搬回 /NM（別的軟體看不到），/Subj 改成一般的名字
function fixNames(doc) {
  var n = doc.countPages();
  for (var i = 0; i < n; i++) {
    var A = doc.findPage(i).get("Annots");
    if (!A || A.isNull() || !A.isArray()) continue;
    for (var k = 0; k < A.length; k++) {
      var a = A.get(k), sj = a.get("Subj"), keep = a.get("SlimlyNM");
      if (keep && keep.isString()) { a.put("NM", doc.newString(keep.asString())); a.delete("SlimlyNM"); a.put("Subj", doc.newString(subtype(a))); continue; }
      if (!sj || !sj.isString()) continue;
      var v = sj.asString();
      if (v.indexOf("slimly:") !== 0) continue;
      a.put("NM", doc.newString(v.indexOf("slimly:new:") === 0 ? v.slice(11) : v));   // 印章留 slimly:stamp:…（再打開才認得）；其他新加的只要一個不重複的名字
      a.put("Subj", doc.newString(subtype(a) === "Stamp" ? "Stamp" : subtype(a)));
    }
  }
}

// 書籤樹：PDFKit 存檔會把 Parent／Last／Prev 寫亂（別的閱讀器可能讀不到書籤）。照 First → Next 走一遍重新接好，標題、目的地、顏色、開合都不動
function fixOutline(doc) {
  var root = doc.getTrailer().get("Root"), ol = root.get("Outlines");
  if (!ol || ol.isNull() || !ol.isDictionary()) return;
  var seen = {};
  function kids(p) {
    var out = [], n = p.get("First");
    while (n && !n.isNull() && n.isDictionary() && !(n.isIndirect() && seen[n.asIndirect()])) { if (n.isIndirect()) seen[n.asIndirect()] = 1; out.push(n); n = n.get("Next"); }
    return out;
  }
  function fix(p) {                                       // 回傳：打開時看得到的子孫數
    var ks = kids(p), vis = 0;
    if (!ks.length) { p.delete("First"); p.delete("Last"); return 0; }
    p.put("First", ks[0]); p.put("Last", ks[ks.length - 1]);
    for (var i = 0; i < ks.length; i++) {
      var k = ks[i], c = k.get("Count");
      k.put("Parent", p);
      if (i > 0) k.put("Prev", ks[i - 1]); else k.delete("Prev");
      if (i < ks.length - 1) k.put("Next", ks[i + 1]); else k.delete("Next");
      var open = !(c && !c.isNull() && c.asNumber() < 0), sub = fix(k);
      if (sub) k.put("Count", open ? sub : -sub); else k.delete("Count");
      vis += 1 + (open ? sub : 0);
    }
    return vis;
  }
  var n = fix(ol);
  if (n) ol.put("Count", n); else ol.delete("Count");
}

// 選項按鈕：PDFKit 存檔會把群組的旗標（單選）與選到的值拿掉，變成一群核取方塊。旗標照來源檔同名的欄位補回（來源也沒有時：
// 子按鈕的「選中」名字各不相同＝選項按鈕），值照哪一顆是選中的
function fixRadios(doc, src, radios) {                  // radios：這次在畫面上選的 {群組名: 選項}
  var af = doc.getTrailer().get("Root").get("AcroForm");
  if (!af || af.isNull() || !af.get("Fields")) return;
  var srcFf = {};
  if (src) {
    var saf = src.getTrailer().get("Root").get("AcroForm");
    var walkS = function (f, pre) { var t = f.get("T"), name = t && !t.isNull() ? pre + (pre ? "." : "") + t.asString() : pre, ff = f.get("Ff"), K = f.get("Kids");
      if (ff && !ff.isNull()) srcFf[name] = ff.asNumber();
      if (K && !K.isNull()) for (var i = 0; i < K.length; i++) walkS(K.get(i), name); };
    if (saf && !saf.isNull() && saf.get("Fields")) { var SF = saf.get("Fields"); for (var j = 0; j < SF.length; j++) walkS(SF.get(j), ""); }
  }
  function onName(w) { var ap = w.get("AP"), N = ap && !ap.isNull() ? ap.get("N") : null, r = null; if (N && !N.isNull() && N.isDictionary()) N.forEach(function (v, k) { if (k !== "Off") r = k; }); return r; }
  function walk(f, pre) {
    var t = f.get("T"), name = t && !t.isNull() ? pre + (pre ? "." : "") + t.asString() : pre, K = f.get("Kids"), ft = f.get("FT");
    if (!K || K.isNull() || !K.length) return;
    var widgets = [], i;
    for (i = 0; i < K.length; i++) { var k = K.get(i); if (k.get("T") && !k.get("T").isNull()) walk(k, name); else widgets.push(k); }
    if (widgets.length < 2 || !ft || ft.isNull() || ft.asName() !== "Btn") return;
    var ff = f.get("Ff"), cur = ff && !ff.isNull() ? ff.asNumber() : 0;
    if (cur & 65536) return;                               // 按鈕（push button）
    var names = {}, distinct = 0;
    for (i = 0; i < widgets.length; i++) { var on = onName(widgets[i]); if (on && !names[on]) { names[on] = 1; distinct++; } }
    var want = srcFf[name] !== undefined ? srcFf[name] : (distinct >= 2 ? (cur | 49152) : cur);
    if (!(want & 32768)) return;                           // 不是選項按鈕
    if (want !== cur) f.put("Ff", want);
    var pick = radios && radios[name] !== undefined ? String(radios[name]) : null, val = "Off";
    for (i = 0; i < widgets.length; i++) {
      var w = widgets[i], on = onName(w);
      if (pick !== null) { w.put("AS", doc.newName(on && on === pick ? on : "Off")); if (on && on === pick) val = on; }
      else { var as = w.get("AS"); if (as && !as.isNull() && as.asName() && as.asName() !== "Off") val = as.asName(); }
    }
    f.put("V", doc.newName(val));
  }
  var F = af.get("Fields");
  for (var j = 0; j < F.length; j++) walk(F.get(j), "");
}

// 原檔目錄裡、PDFKit 存檔會丟掉的東西補回來（輸出裡沒有才補）：附件、JavaScript、關聯檔（電子發票的 XML）、語言、檢視偏好；
// 頁的順序沒變時，頁碼標籤（i、ii…）與開檔跳到的頁也照原本的
function keepCatalog(doc, src, keep) {
  var sr = src.getTrailer().get("Root"), dr = doc.getTrailer().get("Root"), gm = doc.newGraftMap();
  function has(o, k) { var v = o.get(k); return !!v && !v.isNull(); }
  var sn = sr.get("Names");
  if (sn && !sn.isNull()) {
    var dn = dr.get("Names");
    if (!dn || dn.isNull()) { dn = doc.addObject(doc.newDictionary()); dr.put("Names", dn); }
    ["EmbeddedFiles", "JavaScript"].forEach(function (k) { if (has(sn, k) && !has(dn, k)) dn.put(k, gm.graftObject(sn.get(k))); });
  }
  ["AF", "Lang", "ViewerPreferences", "PageMode", "PageLayout"].forEach(function (k) { if (has(sr, k) && !has(dr, k)) dr.put(k, gm.graftObject(sr.get(k))); });
  if (keep.same && has(sr, "PageLabels") && !has(dr, "PageLabels")) dr.put("PageLabels", gm.graftObject(sr.get("PageLabels")));
  if (has(sr, "OpenAction") && !has(dr, "OpenAction")) {
    var oa = sr.get("OpenAction"), pageOf = function (ref) {
      if (!ref || !ref.isIndirect()) return -1;
      for (var i = 0; i < src.countPages(); i++) if (src.findPage(i).asIndirect() === ref.asIndirect()) return i;
      return -1;
    }, dest = function (a) {                                  // [頁 /XYZ x y z]：換成新檔裡同一頁
      var i = pageOf(a.get(0)); if (!keep.same || i < 0 || i >= doc.countPages()) return null;
      var o = doc.newArray(); o.push(doc.findPage(i)); for (var k = 1; k < a.length; k++) o.push(gm.graftObject(a.get(k)));
      return o;
    };
    if (oa.isArray()) { var d0 = dest(oa); if (d0) dr.put("OpenAction", d0); }
    else if (oa.isDictionary()) {
      var D = oa.get("D");
      if (D && !D.isNull() && D.isArray()) { var d1 = dest(D); if (d1) { var na = doc.newDictionary(); na.put("S", doc.newName("GoTo")); na.put("D", d1); dr.put("OpenAction", doc.addObject(na)); } }
      else dr.put("OpenAction", gm.graftObject(oa));
    }
  }
}

// ── E1：存檔從來源檔直接改（不再整份經過 PDFKit 寫一次）──
// pagemap：輸出的每一頁＝來源檔第 s 頁（帶旋轉、裁切），或 donor（PDFKit 那份）第 d 頁（新加的空白頁、插入的檔、再製、辨識後換掉的頁）
function e1Pages(doc, donor, map) {
  var order = [], j;
  for (j = 0; j < map.length; j++) if (map[j].s !== undefined) order.push(map[j].s);
  var same = order.length === doc.countPages() && order.every(function (v, k) { return v === k; });
  if (order.length === 0) {                              // 一頁都不是來源檔的（例：全部辨識後換掉）：先接上 donor 的頁，再刪原本的
    var n0 = doc.countPages();
    for (j = 0; j < map.length; j++) { if (!donor) fail("donor"); doc.graftPage(-1, donor, map[j].d); }
    for (j = n0 - 1; j >= 0; j--) doc.deletePage(j);
    return;
  }
  if (!same) {
    // MuPDF 排頁會把 /AcroForm 從目錄拿掉（欄位還在頁上，就不算表單了）：排完接回去，被刪掉的頁上的欄位從清單拿掉
    var root = doc.getTrailer().get("Root"), af = root.get("AcroForm");
    doc.rearrangePages(order);
    var now = root.get("AcroForm");
    if (af && !af.isNull() && (!now || now.isNull())) { root.put("AcroForm", af); pruneFields(doc, af); }
  }
  for (j = 0; j < map.length; j++) if (map[j].d !== undefined) { if (!donor) fail("donor"); doc.graftPage(j, donor, map[j].d); }
  for (j = 0; j < map.length; j++) {
    var m = map[j]; if (m.s === undefined) continue;
    var po = doc.findPage(j), r = (((m.rot | 0) % 360) + 360) % 360;
    var cur = po.getInheritable("Rotate"), cr = cur && !cur.isNull() ? ((cur.asNumber() % 360) + 360) % 360 : 0;
    if (r !== cr) po.put("Rotate", r);
    if (m.crop) {
      var cb = po.getInheritable("CropBox"); if (!cb || cb.isNull()) cb = po.getInheritable("MediaBox");
      var old = cb && !cb.isNull() ? normRect([cb.get(0).asNumber(), cb.get(1).asNumber(), cb.get(2).asNumber(), cb.get(3).asNumber()]) : null;
      if (!old || !sameRect(old, m.crop, 0.01)) po.put("CropBox", m.crop);
    }
  }
}
function pruneFields(doc, af) {
  var on = {};
  for (var i = 0; i < doc.countPages(); i++) {
    var A = doc.findPage(i).get("Annots");
    if (A && !A.isNull()) for (var k = 0; k < A.length; k++) { var a = A.get(k); if (a.isIndirect()) on[a.asIndirect()] = 1; }
  }
  function walk(list) {
    for (var k = list.length - 1; k >= 0; k--) {
      var f = list.get(k), K = f.get("Kids");
      if (K && !K.isNull() && K.isArray()) { walk(K); if (K.length === 0) list.delete(k); }
      else if (f.isIndirect() && !on[f.asIndirect()]) list.delete(k);
    }
  }
  var F = af.get("Fields"); if (F && !F.isNull() && F.isArray()) walk(F);
}
function normRect(r) { return [Math.min(r[0], r[2]), Math.min(r[1], r[3]), Math.max(r[0], r[2]), Math.max(r[1], r[3])]; }
function sameRect(a, b, tol) { for (var i = 0; i < 4; i++) if (Math.abs(a[i] - b[i]) > tol) return false; return true; }
function annotRect(a) { var r = a.get("Rect"); return r && !r.isNull() && r.length === 4 ? normRect([r.get(0).asNumber(), r.get(1).asNumber(), r.get(2).asNumber(), r.get(3).asNumber()]) : null; }
function findAnnot(A, sub, r, nm, at) {
  var k, a, ar;
  if (nm) for (k = 0; k < A.length; k++) { a = A.get(k); var v = a.get("NM"); if (v && v.isString() && v.asString() === nm && subtype(a) === sub) return k; }
  if (at !== undefined && at !== null && at >= 0 && at < A.length) { a = A.get(at); ar = annotRect(a); if (subtype(a) === sub && ar && sameRect(ar, normRect(r), 1)) return at; }
  for (k = 0; k < A.length; k++) { a = A.get(k); ar = annotRect(a); if (subtype(a) === sub && ar && sameRect(ar, normRect(r), 1)) return k; }
  return -1;
}
// 回覆跟它回的那一個同一個位置：只照「種類＋位置」找會找錯，所以 rm／mv 先全部對到物件，再動手（刪掉一個，後面的序號就變了）
function annotOf(A, x) { var k = findAnnot(A, x.sub, x.r, x.nm, x.k); return k < 0 ? null : A.get(k); }
function dropAnnot(A, a, x) {
  if (a.isIndirect()) dropFromArray(A, a);
  else { var k = findAnnot(A, x.sub, x.r); if (k >= 0) A.delete(k); }
}
// 刪掉的註解底下的回覆（/IRT 指到它的）一起拿掉：不留沒有上一層的回覆
function dropReplies(A, parent) {
  var kids = [], k;
  for (k = 0; k < A.length; k++) { var a = A.get(k), irt = a.get("IRT"); if (irt && !irt.isNull() && sameObj(irt, parent)) kids.push(a); }
  kids.forEach(function (a) { dropFromArray(A, a); var pop = a.get("Popup"); if (pop && !pop.isNull()) dropFromArray(A, pop); dropReplies(A, a); });
}
function sameObj(a, b) { return a && b && a.isIndirect() && b.isIndirect() && a.asIndirect() === b.asIndirect(); }
function dropFromArray(A, o) { for (var k = A.length - 1; k >= 0; k--) if (sameObj(A.get(k), o)) A.delete(k); }
function dropField(doc, w) {                         // 刪掉的表單欄位：從 AcroForm 拿掉（空了的群組一起拿掉）
  var af = doc.getTrailer().get("Root").get("AcroForm");
  if (!af || af.isNull() || !af.get("Fields")) return;
  function walk(list) {
    for (var k = list.length - 1; k >= 0; k--) {
      var f = list.get(k);
      if (sameObj(f, w)) { list.delete(k); continue; }
      var K = f.get("Kids");
      if (K && !K.isNull() && K.isArray()) { walk(K); if (K.length === 0) list.delete(k); }
    }
  }
  walk(af.get("Fields"));
}
// 註解只動有變的：rm＝刪掉的、改過的（用「種類＋位置」對到原檔那一個）；mv＝既有的表單欄位、不認得的註解搬位置；add＝donor 那頁上我們新加的（/Subj 是 slimly: 開頭）
function e1Annots(doc, donor, ops) {
  for (var q = 0; q < ops.length; q++) {
    var op = ops[q], po = doc.findPage(op.i), A = po.get("Annots");
    if (!A || A.isNull()) { A = doc.newArray(); po.put("Annots", A); }
    var rms = (op.rm || []).map(function (x) { return { x: x, a: annotOf(A, x) }; }), mvs = (op.mv || []).map(function (x) { return { x: x, a: annotOf(A, x) }; });
    var relink = [];                                     // 改過的（刪掉舊的、從 PDFKit 那份搬新的）：底下的回覆改指新的那個，不刪
    rms.forEach(function (it) {
      var x = it.x, a = it.a; if (!a) return;
      var pop = a.get("Popup");
      dropAnnot(A, a, x);
      if (pop && !pop.isNull()) dropFromArray(A, pop);
      if (x.sub === "Widget") dropField(doc, a);
      if (!a.isIndirect()) return;
      if (x.re) { var onm = a.get("NM"); relink.push({ old: a, re: x.re, nm: onm && onm.isString() ? onm.asString() : null }); }
      else dropReplies(A, a);
    });
    mvs.forEach(function (it) {
      var x = it.x, a = it.a; if (!a) return;
      a.put("Rect", x.to);
      if (x.note !== undefined) { a.put("Contents", doc.newString(x.note)); a.put("M", doc.newString(pdfDate(new Date()))); }
      var pop = a.get("Popup");
      if (pop && !pop.isNull()) { var pr = annotRect(pop); if (pr) { var dx = x.to[0] - x.r[0], dy = x.to[1] - x.r[1]; pop.put("Rect", [pr[0] + dx, pr[1] + dy, pr[2] + dx, pr[3] + dy]); } }
    });
    if (!op.add || !donor) continue;
    var dp = donor.findPage(op.i), dA = dp.get("Annots"); if (!dA || dA.isNull()) continue;
    var dn = donor.countPages(), idxOf = {};
    for (var t = 0; t < dn; t++) idxOf[donor.findPage(t).asIndirect()] = t;
    var gm = doc.newGraftMap(), put = [];
    for (var k = 0; k < dA.length; k++) {
      var a = dA.get(k), sj = a.get("Subj");
      if (!sj || !sj.isString() || sj.asString().indexOf("slimly:") !== 0) continue;
      a.delete("P");
      var pop = a.get("Popup"); if (pop && !pop.isNull()) pop.delete("P");
      // 連到某頁的連結：目的地的頁先換成第幾頁（不然會把 donor 的整頁一起抄過來）
      var dest = a.get("Dest"), act = a.get("A"), D = dest && !dest.isNull() ? dest : (act && !act.isNull() ? act.get("D") : null);
      var target = -1;
      if (D && !D.isNull() && D.isArray() && D.length > 0 && D.get(0).isIndirect()) { target = idxOf[D.get(0).asIndirect()]; D.put(0, target === undefined ? 0 : target); }
      var g = gm.graftObject(a); g.put("P", po); put.push(g);
      if (pop && !pop.isNull()) { var gp = gm.graftObject(pop); gp.put("P", po); put.push(gp); }
      if (target >= 0) { var gd = g.get("Dest"), ga = g.get("A"), GD = gd && !gd.isNull() ? gd : (ga && !ga.isNull() ? ga.get("D") : null); if (GD && GD.isArray()) GD.put(0, doc.findPage(Math.min(target, doc.countPages() - 1))); }
    }
    for (var u = 0; u < put.length; u++) A.push(put[u]);
    relink.forEach(function (l) {
      var nu = null, k;
      for (k = 0; k < A.length; k++) { var sj = A.get(k).get("Subj"); if (sj && sj.isString() && sj.asString() === "slimly:new:" + l.re) { nu = A.get(k); break; } }
      if (!nu) { dropReplies(A, l.old); return; }
      for (k = 0; k < A.length; k++) { var b = A.get(k), irt = b.get("IRT"); if (irt && !irt.isNull() && sameObj(irt, l.old)) b.put("IRT", nu); }
      if (l.nm && l.nm.indexOf("slimly:") !== 0) nu.put("SlimlyNM", doc.newString(l.nm));      // 存檔前 fixNames 換回原本的 /NM
    });
  }
}
function pdfDate(d) {                                   // D:YYYYMMDDHHmmSS+08'00'（照這台的時區）
  function p2(v) { return (v < 10 ? "0" : "") + v; }
  var off = -d.getTimezoneOffset(), sg = off >= 0 ? "+" : "-"; off = Math.abs(off);
  return "D:" + d.getFullYear() + p2(d.getMonth() + 1) + p2(d.getDate()) + p2(d.getHours()) + p2(d.getMinutes()) + p2(d.getSeconds()) + sg + p2(Math.floor(off / 60)) + "'" + p2(off % 60) + "'";
}
// 回覆的「上一層」是既有的註解：先對到物件（刪、改之前；之後序號會變）
function preThreads(doc, threads) {
  var pre = {};
  (threads || []).forEach(function (t) {
    if (t.i < 0 || t.i >= doc.countPages()) return;
    var A = doc.findPage(t.i).get("Annots"); if (!A || A.isNull()) return;
    (t.replies || []).forEach(function (r) { if (r.parent && !r.parent.new) { var a = annotOf(A, r.parent); if (a) pre[r.rid] = a; } });
  });
  return pre;
}
// 註解回覆串與附加檔案：
//   回覆＝PDFKit 那份畫好的便利貼（/Subj slimly:new:<rid>），這裡接上它回的那一個：/IRT、/RT /R、位置跟上一層一樣、不帶 Popup（Acrobat 把它收進上一層的對話裡）
//   附加檔案＝MuPDF 直接放：檔案內容嵌進 PDF（/FS 帶 /EF），迴紋針圖示，說明放 /Contents
function linkThreads(doc, threads, pre) {
  for (var q = 0; q < (threads || []).length; q++) {
    var t = threads[q]; if (t.i < 0 || t.i >= doc.countPages()) continue;
    var po = doc.findPage(t.i), A = po.get("Annots");
    if (!A || A.isNull()) { A = doc.newArray(); po.put("Annots", A); }
    var bySubj = function (id) { for (var k = 0; k < A.length; k++) { var a = A.get(k), sj = a.get("Subj"); if (sj && sj.isString() && sj.asString() === "slimly:new:" + id) return a; } return null; };
    (t.replies || []).forEach(function (r) {
      var me = bySubj(r.rid); if (!me) return;
      var par = r.parent.new ? bySubj(r.parent.new) : (pre[r.rid] || annotOf(A, r.parent));
      var pop = me.get("Popup"); if (pop && !pop.isNull()) { dropFromArray(A, pop); me.delete("Popup"); }
      if (!par) { dropFromArray(A, me); return; }           // 上一層不見了（例：同時刪掉）：回覆不留
      var nm = par.get("NM"); if (!nm || nm.isNull()) par.put("NM", doc.newString(r.parent.nm || ("slimly-" + r.rid + "-p")));
      me.put("IRT", par); me.put("RT", doc.newName("R")); me.put("F", 28);
      var pr = annotRect(par); if (pr) me.put("Rect", pr);
    });
    (t.files || []).forEach(function (f) {
      var an = doc.loadPage(t.i).createAnnotation("FileAttachment"), now = new Date();
      an.setRect(f.rect);
      an.setFilespec(doc.addEmbeddedFile(f.name, f.mime || "application/octet-stream", readFile(f.path), now, now, false));
      try { an.setIcon(f.icon || "Paperclip"); } catch (e) {}
      if (f.author) an.setAuthor(f.author);
      an.setContents(f.note || "");
      try { an.setCreationDate(now); an.setModificationDate(now); } catch (e) {}
      an.update();
      an.getObject().put("NM", doc.newString(f.fid));
    });
  }
}

// 表單的值（只對來源檔的頁；選項按鈕交給 fixRadios）：值與外觀從 donor（PDFKit 填好的那份）同名欄位抄過來——
// PDFKit 畫的外觀會嵌字型；MuPDF 自己畫，中文會用沒嵌入的字型（別台電腦可能顯示成日文字形）
function e1Forms(doc, donor, forms, map) {
  if (!forms) return;
  for (var j = 0; j < map.length; j++) {
    if (map[j].s === undefined) continue;
    var ws = doc.loadPage(j).getWidgets(), dws = donor ? donor.loadPage(j).getWidgets() : [];
    for (var k = 0; k < ws.length; k++) {
      var w = ws[k], name = w.getName(), t = w.getFieldType(), v = forms[name];
      if (v === undefined || v === null || t === "radiobutton") continue;
      var wo = w.getObject(), dw = null;
      for (var q = 0; q < dws.length; q++) if (dws[q].getName() === name && dws[q].getFieldType() === t) { var r1 = annotRect(dws[q].getObject()), r0 = annotRect(wo); if (r1 && r0 && sameRect(r0, r1, 1)) { dw = dws[q]; break; } }
      try {
        if (dw) {
          var dwo = dw.getObject(), gm = doc.newGraftMap();
          var fo = wo.get("T") && !wo.get("T").isNull() ? wo : wo.get("Parent"), dfo = dwo.get("T") && !dwo.get("T").isNull() ? dwo : dwo.get("Parent");
          var dv = dfo && !dfo.isNull() ? dfo.get("V") : null;
          if (dv && !dv.isNull() && fo && !fo.isNull()) fo.put("V", gm.graftObject(dv));
          var ap = dwo.get("AP"); if (ap && !ap.isNull()) wo.put("AP", gm.graftObject(ap));
          var as = dwo.get("AS"); if (as && !as.isNull()) wo.put("AS", gm.graftObject(as));
          continue;
        }
        // donor 沒有對到（不該發生）：退回 MuPDF 自己設
        if (t === "text") w.setTextValue(String(v));
        else if (t === "combobox" || t === "listbox") w.setChoiceValue(String(v));
        else if (t === "checkbox") { var want = v === true || v === "true" || v === 1, on = w.getValue() !== "Off"; if (want !== on) w.toggle(); }
        else continue;
        w.update();
      } catch (e) {}
    }
  }
}

function cmdApply(inPath, specPath, outPath) {
  var spec = JSON.parse(read(specPath));
  var src = null, so = spec.src;
  if (so) {                                                // 這份是從哪個檔讀進來的；密碼從 stdin 讀：先讀這行，再讀加密的兩行
    var spw = so.pw ? readline() || "" : "";
    try { src = Document.openDocument(so.path); if (src.needsPassword() && !src.authenticatePassword(spw)) src = null; } catch (e) { src = null; }
  }
  var doc;
  if (spec.e1) {
    if (!src) fail("source");
    doc = src;
    var donor = spec.donor ? Document.openDocument(inPath) : null;
    if (donor && donor.needsPassword()) fail("locked");
    e1Pages(doc, donor, spec.pagemap || []);
    var pre = preThreads(doc, spec.threads);
    e1Annots(doc, donor, spec.annops || []);
    e1Forms(doc, donor, spec.forms, spec.pagemap || []);
    linkThreads(doc, spec.threads, pre);
  } else {
    doc = Document.openDocument(inPath);
    if (doc.needsPassword()) fail("locked");
    linkThreads(doc, spec.threads, {});
  }
  var n = doc.countPages();
  var ovl = spec.overlay ? Document.openDocument(spec.overlay) : null, gmO = ovl ? doc.newGraftMap() : null;
  var und = spec.underlay ? Document.openDocument(spec.underlay) : null, gmU = und ? doc.newGraftMap() : null;
  var pages = spec.pages || [];
  for (var i = 0; i < pages.length; i++) {
    var p = pages[i], pi = p.i;
    if (pi < 0 || pi >= n) fail("page " + pi);
    if (p.img && p.img.length) imageOps(doc, pi, p.img);
    redactPass(doc, pi, p.bands, 0, 0, true);                 // 改過的字：只刪那幾行的字（圖、線都不動）
    redactPass(doc, pi, p.white, 2, 1, true);                 // 擦掉：框裡的字、圖的像素、整個蓋住的線
    redactPass(doc, pi, p.redact, 2, 1, false);               // 塗黑：同上，連結與文字註解也一起清
    if (und && p.under !== undefined && p.under !== null) stamp(doc, pi, und, p.under, gmU, true);
    if (ovl && p.over !== undefined && p.over !== null) stamp(doc, pi, ovl, p.over, gmO, false);
    if (p.fields && p.fields.length) addFields(doc, pi, p.fields);
  }
  if (!spec.e1 && src && so.keep) keepCatalog(doc, src, so);   // 舊做法（PDFKit 那份當底）才要補回；E1 的底本來就是來源檔
  fixRadios(doc, src, spec.radios);
  if (spec.outline) setOutline(doc, spec.outline);
  fixOutline(doc);
  fixNames(doc);
  if (spec.meta) { for (var k in spec.meta) { try { doc.setMetaData("info:" + k, String(spec.meta[k])); } catch (e) {} } }
  if (spec.sanitize) sanitize(doc, spec.sanitize);
  var opts = { garbage: "compact", compress: "yes", objstms: "yes" };   // 物件串流：小檔改一點不再變大一成（PDF 1.5 起都讀得了）
  if (!spec.encrypt) opts.decrypt = "yes";               // 來源檔有密碼、這次不加密：存成沒有密碼的（跟舊做法一樣）
  if (spec.encrypt) {
    // 密碼從 stdin 讀（不出現在指令列、不寫進檔案）；選項用 JSON 寫法，密碼裡有逗號、引號也不會斷
    var upw = readline() || "", opw = readline() || "";
    opts.encrypt = "aes-256"; opts["owner-password"] = opw || upw; opts.permissions = String(spec.encrypt.perms | 0);
    if (upw) opts["user-password"] = upw;
  }
  doc.save(outPath, JSON.stringify(opts));
  out({ ok: true, pages: n });
}

// ── weights：每一頁的分量＝內容串流＋用到的圖、表單物件的位元組（同一頁重複用的只算一次）。壓前預估挑樣本頁用 ──
function cmdWeights(path) {
  var doc = Document.openDocument(path);
  if (doc.needsPassword() && !doc.authenticatePassword(readline() || "")) fail("locked");
  function slen(o) { return (o && !o.isNull() && o.isStream()) ? gnum(o, "Length", 0) : 0; }
  function res(r, seen, depth) {
    if (!r || r.isNull() || !r.isDictionary() || depth > 6) return 0;
    var xo = r.get("XObject"), s = 0; if (!xo || xo.isNull() || !xo.isDictionary()) return 0;
    xo.forEach(function (v) {
      if (!v || v.isNull()) return;
      if (v.isIndirect()) { var id = v.asIndirect(); if (seen[id]) return; seen[id] = 1; }
      s += slen(v);
      if (subtype(v) === "Form") s += res(v.get("Resources"), seen, depth + 1);
    });
    return s;
  }
  var n = doc.countPages(), w = [];
  for (var i = 0; i < n; i++) {
    var po = doc.findPage(i), c = po.get("Contents"), s = 0;
    if (c && !c.isNull()) { if (c.isArray()) { for (var k = 0; k < c.length; k++) s += slen(c.get(k)); } else s += slen(c); }
    s += res(po.getInheritable("Resources"), {}, 0);
    w.push(s);
  }
  out({ w: w });
}
// ── sample：把指定的頁原樣搬進一份新的 PDF（串流不重壓）＝壓前預估的樣本 ──
function cmdSample(path, outPath, list) {
  var src = Document.openDocument(path);
  if (src.needsPassword() && !src.authenticatePassword(readline() || "")) fail("locked");
  var doc = new PDFDocument(), idx = String(list || "").split(","), n = 0;
  for (var i = 0; i < idx.length; i++) { var k = parseInt(idx[i], 10); if (k >= 0 && k < src.countPages()) { doc.graftPage(-1, src, k); n++; } }
  doc.save(outPath, "garbage=compact");
  out({ ok: true, pages: n });
}

// ── annmeta：每一頁的註解，照 /Annots 的順序（跟 PDFKit 一樣含 Popup）：種類、/NM、回覆第幾個（/IRT）、/RT、附加檔案的名字與大小 ──
function cmdAnnMeta(path) {
  var doc = Document.openDocument(path);
  if (doc.needsPassword() && !doc.authenticatePassword(readline() || "")) fail("locked");
  var n = doc.countPages(), pages = [];
  for (var i = 0; i < n; i++) {
    var A = doc.findPage(i).get("Annots"), list = [], idx = {}, k, a;
    if (A && !A.isNull() && A.isArray()) {
      for (k = 0; k < A.length; k++) { a = A.get(k); if (a.isIndirect()) idx[a.asIndirect()] = k; }
      for (k = 0; k < A.length; k++) {
        a = A.get(k);
        var e = { k: k, sub: subtype(a) }, nm = a.get("NM"), irt = a.get("IRT"), rt = a.get("RT");
        if (nm && nm.isString()) e.nm = nm.asString();
        if (irt && !irt.isNull() && irt.isIndirect() && idx[irt.asIndirect()] !== undefined) e.irt = idx[irt.asIndirect()];
        if (rt && rt.isName()) e.rt = rt.asName();
        if (e.sub === "FileAttachment") {
          var fs = a.get("FS"), f = { name: "", size: -1, has: false, mime: "" };
          try {
            if (fs && !fs.isNull()) {
              if (fs.isString()) f.name = fs.asString();
              else {
                var pr = doc.getFilespecParams(fs) || {};
                f.name = pr.filename || ""; f.size = pr.size === undefined ? -1 : pr.size; f.mime = pr.mimetype || ""; f.has = !!doc.isEmbeddedFile(fs);
                if (!f.name) { var uf = fs.get("UF"), ff = fs.get("F"); f.name = uf && uf.isString() ? uf.asString() : (ff && ff.isString() ? ff.asString() : ""); }
              }
            }
          } catch (er) {}
          e.file = f;
        }
        list.push(e);
      }
    }
    pages.push(list);
  }
  out({ pages: pages });
}
// ── extract：附加檔案註解（第 pi 頁 /Annots 第 k 個）裡的檔存成 outPath ──
function cmdExtract(path, pi, k, outPath) {
  var doc = Document.openDocument(path);
  if (doc.needsPassword() && !doc.authenticatePassword(readline() || "")) fail("locked");
  if (!(pi >= 0 && pi < doc.countPages())) fail("page");
  var A = doc.findPage(pi).get("Annots");
  if (!A || A.isNull() || !(k >= 0 && k < A.length)) fail("annot");
  var fs = A.get(k).get("FS");
  if (!fs || fs.isNull() || fs.isString() || !doc.isEmbeddedFile(fs)) fail("empty");
  var buf = doc.getEmbeddedFileContents(fs);
  if (!buf) fail("empty");
  buf.save(outPath);
  out({ ok: true, size: buf.getLength() });
}

function main() {
  try {
    var cmd = ARGS[0];
    if (cmd === "text") cmdText(ARGS[1], parseInt(ARGS[2] || "0", 10));
    else if (cmd === "img") cmdImg(ARGS[1], parseInt(ARGS[2], 10), parseInt(ARGS[3], 10), ARGS[4]);
    else if (cmd === "apply") cmdApply(ARGS[1], ARGS[2], ARGS[3]);
    else if (cmd === "scan") cmdScan(ARGS[1], ARGS[2]);
    else if (cmd === "weights") cmdWeights(ARGS[1]);
    else if (cmd === "sample") cmdSample(ARGS[1], ARGS[2], ARGS[3]);
    else if (cmd === "annmeta") cmdAnnMeta(ARGS[1]);
    else if (cmd === "extract") cmdExtract(ARGS[1], parseInt(ARGS[2], 10), parseInt(ARGS[3], 10), ARGS[4]);
    else fail("unknown command " + cmd);
  } catch (e) {
    out({ error: String(e && e.message ? e.message : e) });
  }
}
if (ARGS[0] !== "--lib") main();                 // 測試：把這個檔接在測試腳本前面，第一個參數給 --lib
