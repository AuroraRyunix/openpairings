defmodule PairingsEngine.ThemePacks.ScannerTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.ThemePacks.Scanner

  defp scan(css), do: Scanner.scan(css, "toon")

  describe "accepts" do
    test "token blocks and scoped rules in every allowed spelling" do
      css = """
      [data-theme="toon"] { --bg: #fff; --text: #000; }
      :root[data-theme="toon"] { background: #1d40c8; }
      html[data-theme='toon'] body { color: #000; }
      [data-theme=toon] .card, [data-theme="toon"] .pe-btn:hover { border: 3px solid #000; }
      [data-accent="blue"]:where([data-theme="toon"]) { --accent: #1d40c8; }
      [data-theme="toon"] :where(.pe-table > tbody > tr:nth-child(even)) { background: #fff8e7; }
      [data-theme="toon"]>.page{color:#000}
      """

      assert scan(css) == :ok
    end

    test "@font-face with the pack's own fonts, @keyframes, @media and @supports" do
      css = """
      @font-face { font-family: "T"; src: url("fonts/toon-latin.woff2") format("woff2"); }
      @font-face { font-family: "U"; src: url( fonts/u_2.woff2 ); }
      @keyframes toon-pop { from { opacity: 0 } 50% { opacity: .5 } to { opacity: 1 } }
      @-webkit-keyframes toon-pop { 0% { opacity: 0 } }
      @media (max-width: 768px) { [data-theme="toon"] .page { margin: 0; } }
      @supports (display: grid) { @media print { [data-theme="toon"] body { color: #000; } } }
      """

      assert scan(css) == :ok
    end

    test "braces, quotes and forbidden-looking words inside comments and strings" do
      css = """
      /* @import url(http://evil); } { body { color: red } */
      [data-theme="toon"] .x::after { content: "} body { color: red; "; }
      [data-theme="toon"] .y::after { content: '/* not a comment */'; }
      [data-theme="toon"] .z::after { content: "\\201C"; }
      """

      assert scan(css) == :ok
    end
  end

  describe "refuses" do
    test "@import in any form" do
      assert {:error, _} = scan(~s|@import "x.css";|)
      assert {:error, _} = scan(~s|@IMPORT url(fonts/a.woff2);|)
      assert {:error, _} = scan(~s|/* hi */@import "x.css";|)
      assert {:error, _} = scan(~s|[data-theme="toon"] { color: red; }\n@import "x";|)
    end

    test "an escaped at-rule or property, which a browser reads and a regex does not" do
      assert {:error, reason} = scan(~s|@\\69mport "x.css";|)
      assert reason =~ "backslash"
      assert {:error, _} = scan(~s|[data-theme="toon"] { b\\65havior: url(x); }|)
    end

    test "URLs other than the pack's fonts" do
      for url <- [
            ~s[url(http://evil/x.woff2)],
            ~s[url("https://evil/x.woff2")],
            ~s[url(//evil/x.woff2)],
            ~s[url(fonts/../../secret.woff2)],
            ~s[url("fonts/x.png")],
            ~s[url(data:font/woff2;base64,AAAA)],
            ~s[URL(fonts/X.woff2)],
            ~s[url("javascript:alert(1)")]
          ] do
        assert {:error, _} =
                 scan(~s|@font-face { font-family: "T"; src: #{url}; }|),
               "accepted #{url}"
      end
    end

    test "the other functions that take a URL" do
      assert {:error, _} = scan(~s|[data-theme="toon"] .x { background: image-set("a.png" 1x); }|)

      assert {:error, _} =
               scan(~s|[data-theme="toon"] .x { background: -webkit-image-set("a.png" 1x); }|)

      assert {:error, _} = scan(~s|[data-theme="toon"] .x { background: image("a.png"); }|)
      assert {:error, _} = scan(~s|[data-theme="toon"] .x { background: src("a.png"); }|)
    end

    test "the old ways CSS ran code" do
      assert {:error, _} = scan(~s|[data-theme="toon"] .x { width: expression(alert(1)); }|)
      assert {:error, _} = scan(~s|[data-theme="toon"] .x { width: EXPRESSION (1); }|)
      assert {:error, _} = scan(~s|[data-theme="toon"] .x { behavior: thing; }|)
      assert {:error, _} = scan(~s|[data-theme="toon"] .x { -moz-binding: none; }|)
      assert {:error, _} = scan(~s|[data-theme="toon"] .x::after { content: "javascript:x"; }|)
    end

    test "selectors that are not scoped to the pack" do
      for selector <- [
            "body",
            ":root",
            "html",
            ".card",
            "* ",
            "[data-theme=\"other\"] .card",
            "[data-theme=\"toonish\"] .card",
            ".x [data-theme=\"toon\"]",
            ":not([data-theme=\"toon\"]) .card",
            ":where([data-theme=\"toon\"], body) .card",
            "[data-theme=\"toon\"] .card, body",
            "[data-theme-dark] .card",
            "[data-theme*=\"toon\"]"
          ] do
        assert {:error, reason} = scan("#{selector} { color: red; }"), "accepted #{selector}"
        assert reason =~ "scoped"
      end
    end

    test "an unscoped rule hidden inside @media" do
      assert {:error, _} = scan("@media screen { body { color: red; } }")
      assert {:error, _} = scan("@supports (display: grid) { .card { color: red; } }")
    end

    test "nested rules, other at-rules, and anything that does not parse" do
      assert {:error, _} = scan(~s|[data-theme="toon"] .x { color: red; .y { color: blue; } }|)

      assert {:error, _} =
               scan(~s|[data-theme="toon"] .x { color: red; & body { color: blue; } }|)

      assert {:error, _} = scan("@namespace svg url(http://www.w3.org/2000/svg);")
      assert {:error, _} = scan("@charset \"utf-8\";")
      assert {:error, _} = scan("@layer base { [data-theme=\"toon\"] .x { color: red; } }")
      assert {:error, _} = scan("@page { margin: 0; }")
      assert {:error, _} = scan(~s|[data-theme="toon"] .x { color: red;|)
      assert {:error, _} = scan(~s|[data-theme="toon"] .x { color: red; } }|)
      assert {:error, _} = scan("/* never closed")
      assert {:error, _} = scan(~s|[data-theme="toon"] .x::after { content: "never closed; }|)
      assert {:error, _} = scan(<<255, 254>>)
    end

    test "a string or comment cannot end a block early and smuggle a rule out" do
      # The string holds the brace, so `body` is still inside the block -
      # and the block then never closes.
      assert {:error, _} = scan(~s|[data-theme="toon"] .x { content: "}"; body { color: red; }|)
      # The comment opener inside the string is text, not a comment, so the
      # unscoped rule after it is seen.
      assert {:error, _} =
               scan(~s|[data-theme="toon"] .x { content: "/*"; } body { color: red; } /* */|)
    end
  end
end
