document.querySelectorAll(".copy").forEach(function (button) {
  var code = button.closest(".cmd").querySelector("code");
  var timer;
  function flash(label, state) {
    clearTimeout(timer);
    button.textContent = label;
    if (state) { button.dataset.state = state; } else { delete button.dataset.state; }
    timer = setTimeout(function () {
      button.textContent = "Copy";
      delete button.dataset.state;
    }, 1800);
  }
  function selectInstead() {
    var range = document.createRange();
    range.selectNodeContents(code);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    flash("Selected", null);
  }
  button.addEventListener("click", function () {
    var text = code.textContent.trim();
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () {
        flash("Copied", "done");
      }, selectInstead);
    } else {
      selectInstead();
    }
  });
});

/* The climb ladder. Trunk: F1, F3, F10, F12, F15, F21, F23, F25, F27, then the
   spurs off it, then F27's own continuation to F34/F35/F42/F49. Heights are
   ordinal position, not a claim about anything the levels measure. */
(function () {
  var trunk = ["F1","F3","F10","F12","F15","F21","F23","F25","F27"];
  var spurs = {"F10":"F11","F15":"F18","F21":"F22","F23":"F24"};
  var tail = ["F34","F35","F42","F49"];
  var order = [];
  trunk.forEach(function (k) {
    order.push({ k: k, trunk: true });
    if (spurs[k]) order.push({ k: spurs[k], trunk: false });
  });
  tail.forEach(function (k) { order.push({ k: k, trunk: true }); });

  var el = document.getElementById("ladderSvg");
  var max = order.length;
  order.forEach(function (rung, i) {
    var wrap = document.createElement("div");
    wrap.className = "rung" + (rung.trunk ? " trunk" : " spur");
    var h = 26 + Math.round((i / max) * 130);
    var stem = document.createElement("div");
    stem.className = "stem";
    stem.style.height = h + "px";
    var label = document.createElement("div");
    label.className = "k";
    label.textContent = rung.k;
    wrap.appendChild(stem);
    wrap.appendChild(label);
    el.appendChild(wrap);
  });
})();
