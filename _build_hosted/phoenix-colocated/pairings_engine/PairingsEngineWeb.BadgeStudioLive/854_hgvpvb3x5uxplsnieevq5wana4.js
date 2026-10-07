
      export default {
        mounted() {
          this.onPaste = (e) => {
            const target = e.target
            if (target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable)) return
            const items = Array.from((e.clipboardData && e.clipboardData.items) || [])
            const item = items.find((i) => i.kind === "file" && i.type.startsWith("image/"))
            if (!item) return
            const file = item.getAsFile()
            if (!file) return
            e.preventDefault()
            const ext = (file.type.split("/")[1] || "png").replace("jpeg", "jpg")
            const named = new File([file], `pasted-photo.${ext}`, { type: file.type })
            this.upload("photo", [named])
          }
          window.addEventListener("paste", this.onPaste)
        },
        destroyed() {
          window.removeEventListener("paste", this.onPaste)
        }
      }
    