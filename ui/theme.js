// Reef shared theme toggle. Light is the default; dark is opt-in and
// persisted in localStorage. A tiny inline <head> script applies the stored
// theme before first paint (no flash); this file wires the in-nav toggle and
// keeps the theme-color meta in sync.
(function () {
  "use strict";
  var meta = document.querySelector('meta[name="theme-color"]');
  function apply(t) {
    if (t === "dark")
      document.documentElement.setAttribute("data-theme", "dark");
    else document.documentElement.removeAttribute("data-theme");
    if (meta)
      meta.setAttribute("content", t === "dark" ? "#0a0a0b" : "#f7f8fa");
    try {
      localStorage.setItem("reef-theme", t);
    } catch (e) {}
  }
  function init() {
    var stored = null;
    try {
      stored = localStorage.getItem("reef-theme");
    } catch (e) {}
    apply(stored === "dark" ? "dark" : "light");
    var btn = document.getElementById("themeToggle");
    if (btn)
      btn.addEventListener("click", function () {
        apply(
          document.documentElement.getAttribute("data-theme") === "dark"
            ? "light"
            : "dark",
        );
      });
  }
  if (document.readyState === "loading")
    document.addEventListener("DOMContentLoaded", init);
  else init();
})();
