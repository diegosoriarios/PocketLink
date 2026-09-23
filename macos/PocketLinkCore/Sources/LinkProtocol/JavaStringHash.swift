public enum JavaStringHash {
    public static func hash(_ string: String) -> Int32 {
        var h: Int32 = 0
        for unit in string.utf16 {
            h = 31 &* h &+ Int32(truncatingIfNeeded: unit)
        }
        return h
    }
}
