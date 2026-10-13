#if os(macOS)
import Foundation

/// JavaScript the hunt browser injects: each constant is a function expression that returns JSON (via JSON.stringify).
/// Every function that takes a ref throws `Error("No element with ref …")` when the ref is gone; `HuntBrowser` maps that to `.notFound`.
enum BrowserScripts {
    /// Shared helpers, spliced into each function body.
    private static let prelude = #"""
        const clean = (s) => (s || '').replace(/\s+/g, ' ').trim();
        const trunc = (s, n) => s.length > n ? s.slice(0, n - 1) + '…' : s;
        const find = (ref) => {
            const el = document.querySelector('[data-pb-ref="' + CSS.escape(ref) + '"]');
            if (!el) throw new Error('No element with ref ' + ref);
            return el;
        };
        window.__pbRefSeq = window.__pbRefSeq || 0;
        const refOf = (el) => {
            let r = el.getAttribute('data-pb-ref');
            if (!r) { r = 'r' + (++window.__pbRefSeq); el.setAttribute('data-pb-ref', r); }
            return r;
        };
        const fire = (el, type, init) => {
            const opts = Object.assign({bubbles: true, cancelable: true}, init || {});
            const ev = type === 'input' && typeof InputEvent !== 'undefined' ? new InputEvent(type, opts) : new Event(type, opts);
            return el.dispatchEvent(ev);
        };
        const textOf = (el) => clean(el.innerText !== undefined ? el.innerText : el.textContent);
        const labelOf = (el) => {
            const aria = clean(el.getAttribute('aria-label'));
            if (aria) return aria;
            const by = el.getAttribute('aria-labelledby');
            if (by) {
                const t = clean(by.split(/\s+/).map(id => { const e = document.getElementById(id); return e ? textOf(e) : ''; }).join(' '));
                if (t) return t;
            }
            if (el.id) {
                const l = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
                if (l) { const t = textOf(l); if (t) return t; }
            }
            const wrap = el.closest('label');
            if (wrap && wrap !== el) { const t = textOf(wrap); if (t) return t; }
            for (const a of ['placeholder', 'name', 'title', 'alt']) { const v = clean(el.getAttribute(a)); if (v) return v; }
            if (el.tagName === 'INPUT' && ['submit', 'button', 'reset'].includes(el.type) && el.value) return clean(el.value);
            const own = textOf(el);
            if (own) return own;
            const inner = el.querySelector('[aria-label], img[alt], [title]');
            if (inner) return clean(inner.getAttribute('aria-label') || inner.getAttribute('alt') || inner.getAttribute('title'));
            return '';
        };
    """#

    /// readPage(interactiveOnly) → one line per visible element: `r12 button "Easy Apply"`, `r14 textbox "Email" = "x"`, `r19 text "…"`.
    static let readPage = """
    (function (interactiveOnly) {
        \(prelude)
        const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'META', 'LINK', 'TITLE', 'OPTION', 'OPTGROUP', 'IFRAME',
                              'CANVAS', 'VIDEO', 'AUDIO', 'PICTURE', 'SOURCE', 'BR', 'WBR', 'svg', 'SVG', 'PATH']);
        const BLOCK = new Set(['block', 'flex', 'grid', 'list-item', 'flow-root', 'inline-block', 'inline-flex', 'inline-grid']);
        const ROLES = ['button', 'link', 'tab', 'menuitem', 'option', 'checkbox', 'radio', 'textbox', 'combobox', 'switch', 'menuitemcheckbox', 'menuitemradio'];
        const q = (s) => '"' + s + '"';
        const visible = (el, cs) => {
            if (el.hidden || el.getAttribute('aria-hidden') === 'true') return false;
            if (cs.display === 'none' || cs.visibility === 'hidden') return false;
            if (cs.display === 'contents') return true;
            const r = el.getBoundingClientRect();
            return r.width > 0 || r.height > 0;
        };
        const kindOf = (el) => {
            const tag = el.tagName, role = (el.getAttribute('role') || '').toLowerCase();
            if (tag === 'A' && el.hasAttribute('href')) return 'link';
            if (tag === 'BUTTON') return 'button';
            if (tag === 'INPUT') {
                const t = (el.type || 'text').toLowerCase();
                if (t === 'hidden') return null;
                if (['button', 'submit', 'reset', 'image'].includes(t)) return 'button';
                if (t === 'checkbox') return 'checkbox';
                if (t === 'radio') return 'radio';
                if (t === 'file') return 'file';
                return 'textbox';
            }
            if (tag === 'TEXTAREA') return 'textbox';
            if (tag === 'SELECT') return 'combobox';
            if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) return 'textbox';
            if (/^H[1-6]$/.test(tag) || role === 'heading') return 'heading';
            if (ROLES.includes(role)) return role === 'switch' ? 'checkbox' : role;
            return null;
        };
        const valueOf = (el) => typeof el.value === 'string' ? el.value : textOf(el);
        const describe = (el, kind) => {
            let line = refOf(el) + ' ' + kind + ' ' + q(trunc(labelOf(el), 120));
            if (kind === 'link') line += ' → ' + (el.href || el.getAttribute('href') || '');
            else if (kind === 'textbox') line += ' = ' + q(trunc(clean(el.type === 'password' ? (el.value ? '••••' : '') : valueOf(el)), 80));
            else if (kind === 'combobox') line += ' = ' + q(trunc(clean(el.tagName === 'SELECT' ? (el.selectedOptions[0] ? el.selectedOptions[0].text : '') : valueOf(el)), 80));
            else if (kind === 'checkbox') line += (el.checked || el.getAttribute('aria-checked') === 'true') ? ' [x]' : ' [ ]';
            else if (kind === 'radio') line += (el.checked || el.getAttribute('aria-checked') === 'true') ? ' (x)' : ' ( )';
            else if ((kind === 'tab' || kind === 'option') && (el.selected || el.getAttribute('aria-selected') === 'true')) line += ' [selected]';
            if (el.disabled || el.getAttribute('aria-disabled') === 'true') line += ' (disabled)';
            return line;
        };
        const lines = [];
        let run = '', owner = document.body;
        const flush = () => {
            const t = clean(run);
            run = '';
            if (t && !interactiveOnly) lines.push(refOf(owner) + ' text ' + q(trunc(t, 200)));
        };
        const walk = (el) => {
            if (SKIP.has(el.tagName)) return;
            const cs = getComputedStyle(el);
            if (!visible(el, cs)) return;
            const kind = kindOf(el);
            if (kind) { flush(); lines.push(describe(el, kind)); return; }
            const block = BLOCK.has(cs.display) || cs.display.startsWith('table');
            const prev = owner;
            if (block) { flush(); owner = el; }
            const labelled = el.tagName === 'LABEL' && el.control;   // its text is already on the control's line
            if (labelled) {
                // A hidden control (the usual styled file input) is never walked, so list it here in the label's place.
                const c = el.control, k = kindOf(c);
                if (k && !visible(c, getComputedStyle(c))) { flush(); lines.push(describe(c, k)); return; }
            }
            for (const c of el.childNodes) {
                if (c.nodeType === 3) { if (!labelled) run += c.nodeValue; }
                else if (c.nodeType === 1) walk(c);
            }
            if (block) { flush(); owner = prev; }
        };
        if (document.body) walk(document.body);
        flush();
        return JSON.stringify(lines.join('\\n'));
    })
    """

    /// pageText() → body.innerText with blank-line runs collapsed.
    static let pageText = """
    (function () {
        const t = document.body ? document.body.innerText : '';
        return JSON.stringify(t.replace(/[ \\t]+\\n/g, '\\n').replace(/\\n{3,}/g, '\\n\\n').trim());
    })
    """

    /// rect(ref) → {x, y, width, height, label} in CSS px after scrolling the element to the centre.
    static let rect = """
    (function (ref) {
        \(prelude)
        const el = find(ref);
        el.scrollIntoView({block: 'center', inline: 'nearest'});
        const r = el.getBoundingClientRect();
        return JSON.stringify({x: r.left, y: r.top, width: r.width, height: r.height, label: labelOf(el)});
    })
    """

    /// armClick() → records the target of the next mousedown/click so clickLanded can check a real click reached its element.
    static let armClick = """
    (function () {
        if (!window.__pbClickArmed) {
            window.__pbClickArmed = true;
            document.addEventListener('mousedown', (e) => { window.__pbLastDown = e.target; window.__pbTrusted = e.isTrusted; }, true);
            document.addEventListener('click', (e) => { window.__pbLastClick = e.target; window.__pbTrusted = e.isTrusted; }, true);
        }
        window.__pbLastDown = null;
        window.__pbLastClick = null;
        window.__pbTrusted = false;
        return JSON.stringify(true);
    })
    """

    /// clickLanded(ref) → true when the last recorded click or mousedown hit the element or something inside it.
    /// A hit on an ancestor (an overlay, or the parent when the element has pointer-events: none) means it did not land.
    static let clickLanded = """
    (function (ref) {
        \(prelude)
        const el = find(ref);
        const hit = window.__pbLastClick || window.__pbLastDown;
        return JSON.stringify(!!hit && (hit === el || el.contains(hit)));
    })
    """

    /// click(ref) → label; synthetic pointer/mouse events then element.click().
    static let click = """
    (function (ref) {
        \(prelude)
        const el = find(ref);
        el.scrollIntoView({block: 'center', inline: 'nearest'});
        const r = el.getBoundingClientRect();
        const init = {bubbles: true, cancelable: true, view: window, button: 0, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2};
        const mk = (t) => (t.startsWith('pointer') && typeof PointerEvent !== 'undefined') ? new PointerEvent(t, init) : new MouseEvent(t, init);
        el.dispatchEvent(mk('pointerdown')); el.dispatchEvent(mk('mousedown'));
        if (typeof el.focus === 'function') el.focus();
        el.dispatchEvent(mk('pointerup')); el.dispatchEvent(mk('mouseup'));
        if (typeof el.click === 'function') el.click(); else el.dispatchEvent(mk('click'));
        return JSON.stringify(labelOf(el));
    })
    """

    /// setValue(ref, text, clear) → label; uses the native value setter so React/Vue see the change, then fires input and change.
    static let setValue = """
    (function (ref, text, clear) {
        \(prelude)
        const el = find(ref);
        el.scrollIntoView({block: 'center', inline: 'nearest'});
        if (typeof el.focus === 'function') el.focus();
        if (el.isContentEditable) {
            if (clear) el.textContent = '';
            const sel = window.getSelection();
            if (sel) { sel.selectAllChildren(el); sel.collapseToEnd(); }
            if (!document.execCommand('insertText', false, text)) el.textContent += text;
            fire(el, 'input'); fire(el, 'change');
            return JSON.stringify(labelOf(el));
        }
        const tag = el.tagName;
        if (tag !== 'INPUT' && tag !== 'TEXTAREA') throw new Error('Element ' + ref + ' is not a text field (' + tag.toLowerCase() + ')');
        const proto = tag === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const d = Object.getOwnPropertyDescriptor(proto, 'value');
        const next = clear ? text : el.value + text;
        if (d && d.set) d.set.call(el, next); else el.value = next;
        fire(el, 'input', {inputType: 'insertText', data: text});
        fire(el, 'change');
        return JSON.stringify(labelOf(el));
    })
    """

    /// selectOption(ref, value) → chosen option text; matches by value, then exact visible text, then contains.
    static let selectOption = """
    (function (ref, value) {
        \(prelude)
        const el = find(ref);
        if (el.tagName !== 'SELECT') throw new Error('Element ' + ref + ' is not a <select>; click it and then click the option instead');
        const opts = Array.from(el.options), want = clean(value).toLowerCase();
        const opt = opts.find(o => o.value === value)
            || opts.find(o => clean(o.text).toLowerCase() === want)
            || (want ? opts.find(o => clean(o.text).toLowerCase().includes(want)) : null);
        if (!opt) throw new Error('No option "' + value + '" in ' + ref + '. Options: ' + opts.slice(0, 40).map(o => clean(o.text)).join(', '));
        const d = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value');
        if (d && d.set) d.set.call(el, opt.value); else el.value = opt.value;
        fire(el, 'input'); fire(el, 'change');
        return JSON.stringify(clean(opt.text));
    })
    """

    /// pressKey(key) → label of the focused element; keydown/keypress/keyup, plus implicit form submit on Enter and focus move on Tab.
    static let pressKey = """
    (function (key) {
        \(prelude)
        const codes = {Enter: 13, Tab: 9, Escape: 27, Backspace: 8, Delete: 46, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39,
                       Home: 36, End: 35, PageUp: 33, PageDown: 34, Space: 32, ' ': 32};
        const k = key === 'Space' ? ' ' : key;
        const code = codes[key] || (k.length === 1 ? k.toUpperCase().charCodeAt(0) : 0);
        const codeName = k === ' ' ? 'Space' : (codes[key] ? key : (k.length === 1 ? 'Key' + k.toUpperCase() : key));
        const el = document.activeElement || document.body;
        const init = {key: k, code: codeName, bubbles: true, cancelable: true, composed: true};
        const mk = (t) => {
            const e = new KeyboardEvent(t, init);
            for (const p of ['keyCode', 'which']) Object.defineProperty(e, p, {get: () => code});
            return e;
        };
        const allowed = el.dispatchEvent(mk('keydown'));
        if (k.length === 1) el.dispatchEvent(mk('keypress'));
        if (allowed) {
            if (k === 'Enter' && el.tagName === 'INPUT' && el.form) {
                if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
            } else if (k === 'Tab') {
                const all = Array.from(document.querySelectorAll('a[href], button, input, select, textarea, [tabindex]'))
                    .filter(e => !e.disabled && e.tabIndex >= 0 && e.type !== 'hidden' && e.getBoundingClientRect().width > 0);
                const i = all.indexOf(el);
                const next = all[(i + 1) % Math.max(all.length, 1)];
                if (next) next.focus();
            }
        }
        el.dispatchEvent(mk('keyup'));
        return JSON.stringify(labelOf(document.activeElement || el));
    })
    """

    /// scrollBy(dx, dy) → {x, y, maxY} after scrolling the window.
    static let scrollBy = """
    (function (dx, dy) {
        const el = document.scrollingElement || document.documentElement;
        window.scrollBy({left: dx, top: dy, behavior: 'instant'});
        return JSON.stringify({x: window.scrollX, y: window.scrollY, maxY: Math.max(0, el.scrollHeight - window.innerHeight)});
    })
    """

    /// scrollTo(ref) → label after scrolling the element to the centre.
    static let scrollTo = """
    (function (ref) {
        \(prelude)
        const el = find(ref);
        el.scrollIntoView({block: 'center', inline: 'nearest'});
        return JSON.stringify(labelOf(el));
    })
    """

    /// findFileInput(ref) → ref of the file input for `ref`: itself, its label target, a descendant, a nearby ancestor's, or the page's only one.
    static let findFileInput = """
    (function (ref) {
        \(prelude)
        const el = find(ref);
        const isFile = (e) => !!e && e.tagName === 'INPUT' && e.type === 'file';
        let input = isFile(el) ? el : null;
        if (!input && el.tagName === 'LABEL' && isFile(el.control)) input = el.control;
        if (!input && el.hasAttribute('for')) { const t = document.getElementById(el.getAttribute('for')); if (isFile(t)) input = t; }
        if (!input) input = el.querySelector('input[type=file]');
        for (let a = el.parentElement, i = 0; !input && a && i < 5; a = a.parentElement, i++) input = a.querySelector('input[type=file]');
        if (!input) { const all = document.querySelectorAll('input[type=file]'); if (all.length === 1) input = all[0]; }
        if (!input) throw new Error('No file input near ' + ref);
        return JSON.stringify(refOf(input));
    })
    """

    /// setFiles(ref, name, mime, base64) → files.length after assigning a DataTransfer-built FileList and firing input/change.
    static let setFiles = """
    (function (ref, name, mime, base64) {
        \(prelude)
        const el = find(ref);
        if (!(el.tagName === 'INPUT' && el.type === 'file')) throw new Error('Element ' + ref + ' is not a file input');
        const bin = atob(base64), bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        const dt = new DataTransfer();
        dt.items.add(new File([bytes], name, {type: mime}));
        el.files = dt.files;
        fire(el, 'input'); fire(el, 'change');
        return JSON.stringify(el.files.length);
    })
    """

    /// filesCount(ref) → number of files on the input, or -1 when it is not a file input.
    static let filesCount = """
    (function (ref) {
        \(prelude)
        const el = find(ref);
        return JSON.stringify(el.files ? el.files.length : -1);
    })
    """

    // MARK: LinkedIn sign-in (the values arrive as script arguments and stay inside the page)

    /// fillLogin(email, password) → true when LinkedIn's email and password fields were both found and set.
    static let fillLogin = """
    (function (email, password) {
        \(prelude)
        const user = document.querySelector('#username') || document.querySelector('input[name=session_key]');
        const pass = document.querySelector('#password') || document.querySelector('input[name=session_password]');
        if (!user || !pass) return JSON.stringify(false);
        const d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
        for (const [el, text] of [[user, email], [pass, password]]) {
            if (typeof el.focus === 'function') el.focus();
            if (d && d.set) d.set.call(el, text); else el.value = text;
            fire(el, 'input', {inputType: 'insertText'});
            fire(el, 'change');
        }
        return JSON.stringify(true);
    })
    """

    /// submitLogin() → true when the form holding the password field was found; clicks its submit button, else requestSubmit().
    static let submitLogin = """
    (function () {
        const pass = document.querySelector('#password') || document.querySelector('input[name=session_password]');
        const form = pass ? (pass.form || pass.closest('form')) : null;
        if (!form) return JSON.stringify(false);
        const button = form.querySelector('button[type=submit], input[type=submit]');
        if (button) button.click();
        else if (form.requestSubmit) form.requestSubmit();
        else form.submit();
        return JSON.stringify(true);
    })
    """

    /// loginError() → the visible text of #error-for-password / #error-for-username, or "".
    static let loginError = """
    (function () {
        \(prelude)
        for (const id of ['error-for-password', 'error-for-username']) {
            const el = document.getElementById(id);
            if (!el) continue;
            const cs = getComputedStyle(el);
            if (cs.display === 'none' || cs.visibility === 'hidden') continue;
            const t = textOf(el);
            if (t) return JSON.stringify(t);
        }
        return JSON.stringify('');
    })
    """
}
#endif
