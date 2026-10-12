// the download page reads release.json (written by app/macos/build.sh) and fills in the one
// button, its size, the requirements, and an honest signing note. it never starts a
// download by itself, and it says so when there is nothing to download.
(function () {
  "use strict";

  var MANIFEST = "release.json";

  function $(selector) { return document.querySelector(selector); }

  function megabytes(bytes) {
    var value = bytes / 1000000;
    return (value < 10 ? value.toFixed(1) : Math.round(value)) + " megabytes";
  }

  function macOSName(version) {
    var names = { "13": "13 Ventura", "14": "14 Sonoma", "15": "15 Sequoia", "26": "26 Tahoe" };
    var major = String(version).split(".")[0];
    return (names[major] || major) + " or newer";
  }

  function processors(architectures) {
    var apple = architectures.indexOf("arm64") !== -1;
    var intel = architectures.indexOf("x86_64") !== -1;
    if (apple && intel) return "Apple silicon or Intel";
    if (apple) return "Apple silicon only, for now";
    if (intel) return "Intel only, for now";
    return "Unknown";
  }

  // the signing note says plainly what the user will see when they open the app.
  function signingNote(release) {
    if (release.signing === "developer-id" && release.notarized) return "";
    return "This early build is not notarized by Apple yet, so macOS will warn you the first time you open it. " +
      "To open it anyway, open System Settings, then Privacy and Security, and choose Open Anyway next to sirven.";
  }

  function apply(release) {
    var button = $("[data-download]");
    button.href = release.url || release.file;
    button.removeAttribute("aria-disabled");
    button.setAttribute("download", "");
    $("[data-meta]").textContent = "Version " + release.version + ", " + megabytes(release.bytes) + ", disk image";
    $("[data-requirement-macos]").textContent = macOSName(release.minimumMacOS);
    $("[data-requirement-processor]").textContent = processors(release.architectures || []);
    if (release.appBytes) $("[data-requirement-space]").textContent = "About " + megabytes(release.appBytes) + " once installed";

    var note = signingNote(release);
    if (note) {
      $("[data-notice]").textContent = note;
      $("[data-notice]").hidden = false;
    }
    $("[data-sha]").textContent = release.sha256;
    $("[data-verify]").hidden = false;
  }

  function unavailable() {
    var button = $("[data-download]");
    button.removeAttribute("href");
    $("[data-meta]").textContent = "The download is not available right now. Please try again later.";
  }

  function showPlatformNote() {
    var platform = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
    if (!/mac/i.test(platform)) $("[data-platform-note]").hidden = false;
  }

  function enter() {
    var items = document.querySelectorAll(".enter");
    for (var i = 0; i < items.length; i++) items[i].style.setProperty("--index", i);
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        for (var j = 0; j < items.length; j++) items[j].classList.add("shown");
      });
    });
  }

  // a disabled link must not navigate.
  $("[data-download]").addEventListener("click", function (event) {
    if (this.getAttribute("aria-disabled") === "true" || !this.getAttribute("href")) event.preventDefault();
  });

  document.documentElement.classList.remove("no-script");
  showPlatformNote();
  enter();
  fetch(MANIFEST, { cache: "no-store" })
    .then(function (response) { if (!response.ok) throw new Error(response.status); return response.json(); })
    .then(apply)
    .catch(unavailable);
})();
