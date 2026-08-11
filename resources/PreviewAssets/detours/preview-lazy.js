(function () {
  "use strict";

  // A long file keeps only its first lines. Each further chunk is asked for as it is scrolled
  // towards, so a file nobody scrolls through is never read past its first screenful.
  var DISTANCE_FROM_END = 3000;

  // The page scrolls its body, not the window, so the body is what has to be watched and measured.
  function scroller() {
    var body = document.body;
    if (body && body.scrollHeight > body.clientHeight) {
      return body;
    }
    return document.scrollingElement || document.documentElement;
  }

  function start() {
    var list = document.getElementById("source-preview");
    if (!list) {
      return;
    }

    var total = parseInt(list.getAttribute("data-chunks") || "0", 10);
    var scheme = list.getAttribute("data-chunk-scheme");
    var next = 1;
    var fetching = false;

    function appendIfNeeded() {
      if (next > total) {
        scroller().removeEventListener("scroll", onScroll);
        window.removeEventListener("scroll", onScroll);
        return;
      }
      if (fetching || !scheme) {
        return;
      }
      var view = scroller();
      var remaining = view.scrollHeight - view.scrollTop - view.clientHeight;
      if (remaining > DISTANCE_FROM_END) {
        return;
      }
      fetching = true;
      // Asked for only now, and only this far. Nothing beyond this is read.
      fetch(scheme + "://chunk/chunk-" + next + ".html")
        .then(function (response) { return response.text(); })
        .then(function (markup) {
          next += 1;
          list.insertAdjacentHTML("beforeend", markup);
          fetching = false;
          // One chunk may still leave the end within reach, on a tall window.
          window.requestAnimationFrame(appendIfNeeded);
        })
        .catch(function () {
          fetching = false;
        });
    }

    function onScroll() {
      appendIfNeeded();
    }

    scroller().addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("scroll", onScroll, { passive: true });
    appendIfNeeded();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
