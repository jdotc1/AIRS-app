/// Presentation-only navigation; displayed pages are one-based, document indices zero-based.
struct LeafPageNavigation {
    private(set) var index = 0
    var input = "1" { didSet { isInvalid = false } }
    private(set) var isInvalid = false

    mutating func go(pageCount: Int) {
        guard !input.isEmpty, input.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let number = Int(input), number >= 1, number <= pageCount else {
            isInvalid = true
            return
        }
        select(number - 1, pageCount: pageCount)
    }

    mutating func select(_ index: Int, pageCount: Int) {
        guard index >= 0, index < pageCount else { return }
        self.index = index
        input = String(index + 1)
        isInvalid = false
    }
}
