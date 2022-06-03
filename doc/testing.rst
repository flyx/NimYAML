==============
Testing Ground
==============

Input is being processed on the fly by a friendly web service and output is
updated as you type.

.. raw:: html
  <section id="testingground">
    <table style="width: 100%; table-layout: fixed">
      <thead>
        <tr>
          <th>Input</th>
          <th>Output</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td style="width: 50%; height: 550px; vertical-align: top;">
            <textarea id="yaml-input" style="width: 100%; height: 100%">
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
          </td>
          <td style="width: 50%; vertical-align: top; height: 550px; padding-left: 10px">
            <div style="width:100%; height:100%; overflow: scroll">
              <pre id="yaml-output" style="width: 100%"/>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
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
        <input type="radio" name="style" id="style-canonical" value="canonical" checked="checked"/>
        <label for="style-canonical">Canonical</label>
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
  </section>
  <script type="text/javascript">
    function setTextContent(element, text) {
      element.innerHTML = text;
    }
    function parse() {
      var r = new XMLHttpRequest();
      var params = "style=" + encodeURIComponent(document.querySelector(
        "input[name=style]:checked").value) + "&input=" + encodeURIComponent(
        document.getElementById("yaml-input").value);
      r.open("POST", "/webservice/", true);
      r.setRequestHeader("Content-type", "application/x-www-form-urlencoded");
      r.onreadystatechange = function() {
        if (r.readyState == 4) {
          var output = document.getElementById("yaml-output");
          if (r.status == 200) {
            var result = JSON.parse(r.responseText);
            switch(result.code) {
            case 0:
              setTextContent(output, result.output);
              output.style.color = "black";
              break;
            case 1:
              setTextContent(output, "Parser error at line " + result.line +
                  ", column " + result.column + ":\n" + result.message +
                  "\n\n" + result.detail);
              output.style.color = "orange";
              break;
            case 2:
              setTextContent(output, "Presenter error:\n" + result.message);
              output.style.color = "orange";
              break;
            }
          } else if (r.status == 0) {
            setTextContent(output,
              "YAML parser server does not seem to be available.");
            output.style.color = "red";
          } else {
            setTextContent(output, "Status: " + r.status +
              "\nException occurred on server:\n\n" + r.responseText);
            output.style.color = "red";
          }
        }
      }
      r.send(params);
    }
    document.getElementById("yaml-input").addEventListener('input', parse,
        false);
    var radios = document.querySelectorAll("input[name=style]");
    for (var i = 0; i < radios.length; ++i) {
      radios[i].onclick = parse;
    }
    parse();
  </script>
