
  export default {
    mounted() {
      this.local = this.el.querySelector('input[type="datetime-local"]');
      this.utc = this.el.querySelector('input[type="hidden"]');
      this.onInput = () => {
        const value = this.local.value;
        const at = value ? new Date(value) : null;
        this.utc.value = at && !isNaN(at) ? at.toISOString() : "";
      };
      this.local.addEventListener("input", this.onInput);
      this.local.addEventListener("change", this.onInput);
      this.show();
    },
    updated() { this.show(); },
    destroyed() {
      this.local.removeEventListener("input", this.onInput);
      this.local.removeEventListener("change", this.onInput);
    },
    show() {
      const at = this.utc.value ? new Date(this.utc.value) : null;
      if (!at || isNaN(at)) { this.local.value = ""; return; }
      const pad = (n) => String(n).padStart(2, "0");
      this.local.value =
        at.getFullYear() + "-" + pad(at.getMonth() + 1) + "-" + pad(at.getDate()) +
        "T" + pad(at.getHours()) + ":" + pad(at.getMinutes());
    }
  };
