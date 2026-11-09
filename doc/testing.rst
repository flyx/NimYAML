==============
Testing Ground
==============

Input is processed on the fly by NimYAML, compiled to JavaScript and running
locally in your browser. Your input is not sent anywhere. Output is updated as
you type.

.. raw:: html
  <section id="testingground">
    <div id="style-options">
      <div class="style-option">Output style:</div>
      <div class="style-option">
        <input type="radio" name="style" id="style-minimal" value="minimal"/>
        <label for="style-minimal">Minimal</label>
      </div>
      <div class="style-option">
        <input type="radio" name="style" id="style-default" value="default"/>
        <label for="style-default">Default</label>
      </div>
      <div class="style-option">
        <input type="radio" name="style" id="style-explanatory" value="explanatory" checked="checked"/>
        <label for="style-explanatory">Explanatory</label>
      </div>
      <div class="style-option">
        <input type="radio" name="style" id="style-block" value="block"/>
        <label for="style-block">Block Only</label>
      </div>
      <div class="style-option">
        <input type="radio" name="style" id="style-json" value="json"/>
        <label for="style-json">JSON</label>
      </div>
      <div class="style-option">
        <input type="radio" name="style" id="style-tokens" value="tokens"/>
        <label for="style-tokens">Tokens</label>
      </div>
    </div>
    <div id="split-view">
      <div class="pane">
        <h2>Input</h2>
        <textarea id="yaml-input" spellcheck="false">
  - test some
  - {YAML: here}
  - foo: bar
    ? [1, 2, 3]
    : !!str "string"
  -
    ? &amp;a anchor
    : !!bool yes
    ? reference to anchor
    : *a</textarea>
      </div>
      <div class="pane">
        <h2>Output</h2>
        <div class="output-scroll">
          <pre id="yaml-output"></pre>
        </div>
      </div>
    </div>
  </section>
  <script type="text/javascript">
    // NimYAML runs in a Web Worker (testingground.js, compiled from
    // doc/testingground.nim) so that large inputs do not block the page.
    var output = document.getElementById("yaml-output");
    var worker = null;
    var busySince = null; // time the current request was sent, null if idle
    var pending = null;   // latest request that has not been sent yet

    function showText(text, color) {
      output.textContent = text;
      output.style.color = color;
    }

    function startWorker() {
      worker = new Worker("testingground.js");
      worker.onmessage = function(e) {
        var result = e.data;
        switch (result.code) {
        case 0:
          // output is HTML-escaped by the worker
          output.innerHTML = result.output;
          output.style.color = "black";
          break;
        case 1:
          showText("Parser error at line " + result.line + ", column " +
              result.column + ":\n" + result.message + "\n\n" +
              result.detail, "orange");
          break;
        case 2:
          showText("Presenter error:\n" + result.message, "orange");
          break;
        default:
          showText("Unexpected error:\n" + result.message, "red");
        }
        busySince = null;
        sendPending();
      };
      worker.onerror = function(e) {
        showText("The YAML processor could not be loaded or crashed: " +
            e.message, "red");
        busySince = null;
        e.preventDefault();
      };
    }

    function sendPending() {
      if (pending === null) return;
      worker.postMessage(pending);
      pending = null;
      busySince = Date.now();
    }

    function parse() {
      pending = {
        input: document.getElementById("yaml-input").value,
        style: document.querySelector("input[name=style]:checked").value
      };
      if (busySince === null) {
        sendPending();
      } else if (Date.now() - busySince > 1000) {
        // the previous input takes long to process; do not wait for it.
        worker.terminate();
        startWorker();
        busySince = null;
        sendPending();
      }
      // otherwise, the pending request is sent when the current one finishes.
    }

    startWorker();
    document.getElementById("yaml-input").addEventListener("input", parse,
        false);
    var radios = document.querySelectorAll("input[name=style]");
    for (var i = 0; i < radios.length; ++i) {
      radios[i].onclick = parse;
    }
    parse();
  </script>
