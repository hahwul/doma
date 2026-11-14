(function () {
  "use strict";

  var container = document.querySelector("[data-search]");
  if (!container) return;

  var input = container.querySelector(".docs-search-input");
  var results = container.querySelector(".docs-search-results");
  if (!input || !results) return;

  var BASE = (function () {
    var b = document.querySelector('meta[name="base-url"]');
    return b ? b.getAttribute("content") || "" : "";
  })();

  var index = null;
  var loading = false;
  var fuse = null;
  var activeIdx = -1;

  function loadIndex() {
    if (index || loading) return Promise.resolve(index);
    loading = true;
    return fetch(BASE + "/search.json", { credentials: "same-origin" })
      .then(function (r) {
        if (!r.ok) throw new Error("search index unavailable");
        return r.json();
      })
      .then(function (data) {
        index = data;
        if (window.Fuse) {
          fuse = new window.Fuse(index, {
            keys: [
              { name: "title", weight: 0.6 },
              { name: "description", weight: 0.3 },
              { name: "content", weight: 0.1 },
            ],
            threshold: 0.35,
            ignoreLocation: true,
            includeMatches: true,
            minMatchCharLength: 2,
          });
        }
        return index;
      })
      .catch(function (err) {
        console.warn("[doma docs search]", err);
        index = [];
      })
      .then(function () {
        loading = false;
        return index;
      });
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function snippet(content, query) {
    if (!content) return "";
    var clean = content.replace(/\s+/g, " ").trim();
    if (!query) return escapeHtml(clean.slice(0, 120));

    var lc = clean.toLowerCase();
    var q = query.toLowerCase();
    var i = lc.indexOf(q);
    if (i < 0) return escapeHtml(clean.slice(0, 120));

    var start = Math.max(0, i - 40);
    var end = Math.min(clean.length, i + q.length + 80);
    var prefix = start > 0 ? "…" : "";
    var suffix = end < clean.length ? "…" : "";
    var slice = clean.slice(start, end);
    var qInSlice = lc.slice(start, end).indexOf(q);
    if (qInSlice < 0) return prefix + escapeHtml(slice) + suffix;
    return (
      prefix +
      escapeHtml(slice.slice(0, qInSlice)) +
      "<mark>" +
      escapeHtml(slice.slice(qInSlice, qInSlice + q.length)) +
      "</mark>" +
      escapeHtml(slice.slice(qInSlice + q.length)) +
      suffix
    );
  }

  function render(query, hits) {
    if (!query) {
      results.hidden = true;
      results.innerHTML = "";
      activeIdx = -1;
      return;
    }
    if (!hits.length) {
      results.hidden = false;
      results.innerHTML =
        '<div class="docs-search-empty">No matches for “' +
        escapeHtml(query) +
        "”</div>";
      activeIdx = -1;
      return;
    }
    var html = hits
      .slice(0, 8)
      .map(function (hit, i) {
        var item = hit.item || hit;
        var url = (BASE + (item.url || "/")).replace(/\/+/g, "/");
        return (
          '<a class="docs-search-result" role="option" data-idx="' +
          i +
          '" href="' +
          escapeHtml(url) +
          '">' +
          '<span class="docs-search-result-title">' +
          escapeHtml(item.title || item.url) +
          "</span>" +
          '<span class="docs-search-result-snippet">' +
          snippet(item.description || item.content, query) +
          "</span>" +
          "</a>"
        );
      })
      .join("");
    results.hidden = false;
    results.innerHTML = html;
    activeIdx = -1;
  }

  function search(query) {
    if (!query) return render("", []);
    if (fuse) {
      render(query, fuse.search(query));
      return;
    }
    if (!index) return;
    var q = query.toLowerCase();
    var hits = index.filter(function (e) {
      return (
        (e.title && e.title.toLowerCase().indexOf(q) >= 0) ||
        (e.description && e.description.toLowerCase().indexOf(q) >= 0) ||
        (e.content && e.content.toLowerCase().indexOf(q) >= 0)
      );
    });
    render(
      query,
      hits.map(function (e) {
        return { item: e };
      })
    );
  }

  function move(delta) {
    var items = results.querySelectorAll(".docs-search-result");
    if (!items.length) return;
    activeIdx = (activeIdx + delta + items.length) % items.length;
    items.forEach(function (el, i) {
      el.classList.toggle("is-active", i === activeIdx);
      if (i === activeIdx) el.scrollIntoView({ block: "nearest" });
    });
  }

  function activate() {
    var items = results.querySelectorAll(".docs-search-result");
    if (activeIdx >= 0 && items[activeIdx]) {
      window.location.href = items[activeIdx].getAttribute("href");
    }
  }

  input.addEventListener("focus", function () {
    loadIndex().then(function () {
      if (input.value) search(input.value);
    });
  });

  input.addEventListener("input", function () {
    var q = input.value.trim();
    loadIndex().then(function () {
      search(q);
    });
  });

  input.addEventListener("keydown", function (e) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      move(1);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      move(-1);
    } else if (e.key === "Enter") {
      if (activeIdx >= 0) {
        e.preventDefault();
        activate();
      }
    } else if (e.key === "Escape") {
      input.value = "";
      render("", []);
      input.blur();
    }
  });

  document.addEventListener("click", function (e) {
    if (!container.contains(e.target)) {
      results.hidden = true;
      activeIdx = -1;
    }
  });

  document.addEventListener("keydown", function (e) {
    if ((e.key === "/" || (e.key === "k" && (e.metaKey || e.ctrlKey))) &&
        document.activeElement !== input) {
      var t = e.target;
      var typing =
        t &&
        (t.tagName === "INPUT" ||
          t.tagName === "TEXTAREA" ||
          t.isContentEditable);
      if (typing && e.key === "/") return;
      e.preventDefault();
      input.focus();
      input.select();
    }
  });
})();
