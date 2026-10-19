/// View-local input identity must distinguish canonically equivalent UTF-8 spellings.
struct ExactKeyInput: Equatable {
    var value = ""
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }
}
