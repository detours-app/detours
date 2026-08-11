(function () {
  "use strict";

  // A long file is built a screenful at a time. The rest of it rides along as plain text, which the
  // page reads but does not build anything for, and lines are added as they are scrolled towards.
  var CHUNK_LINES = 1200;
  var DISTANCE_FROM_END = 3000;

  function start() {
    var list = document.getElementById("source-preview");
    var tail = document.getElementById("source-tail");
    if (!list || !tail) {
      return;
    }

    var rest = tail.textContent || "";
    tail.remove();
    var cursor = 0;

    function nextChunk() {
      if (cursor >= rest.length) {
        return null;
      }
      var end = cursor;
      for (var count = 0; count < CHUNK_LINES; count++) {
        var newline = rest.indexOf("\n", end);
        if (newline === -1) {
          end = rest.length;
          break;
        }
        end = newline + 1;
      }
      var slice = rest.slice(cursor, end);
      cursor = end;
      return slice;
    }

    function appendIfNeeded() {
      if (cursor >= rest.length) {
        window.removeEventListener("scroll", onScroll);
        return;
      }
      var remaining = document.documentElement.scrollHeight
        - window.scrollY
        - window.innerHeight;
      if (remaining > DISTANCE_FROM_END) {
        return;
      }
      var slice = nextChunk();
      if (slice) {
        list.insertAdjacentHTML("beforeend", slice);
      }
      // Adding one chunk may still leave the end within reach, on a tall window.
      window.requestAnimationFrame(appendIfNeeded);
    }

    function onScroll() {
      appendIfNeeded();
    }

    window.addEventListener("scroll", onScroll, { passive: true });
    appendIfNeeded();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
