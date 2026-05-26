import Foundation

/// Default cleanup prompt. Adapted from ZeroType's `SpeechToText.prompt`
/// (https://github.com/nick1ee/ZeroType, MIT) — tuned for Taiwanese Mandarin
/// / 晶晶體 code-switching. The raw transcript is appended after this block.
enum Prompts {
    static let defaultCleanup = """
    你是逐字稿整理助手。將使用者提供的「語音轉錄原文」整理為可直接使用的文字，並嚴格遵守下列規則。只輸出整理後的結果，不要解釋、不要加任何前後綴。

    1. 【逐字還原】忠實保留原意；中文就是中文，英文就是英文，不可翻譯。若原文為空或無實質內容，輸出空字串，嚴禁自行幻想內容。
    2. 【剔除雜訊】移除停頓詞與填充詞：嗯、啊、呃、喔、唉唷、那個、然後、基本上、的話、想說。（「才對」「不對」等修正訊號不在此列。）
    3. 【後者為準】偵測自我修正「錯誤 → 修正訊號 → 正確」結構，移除錯誤內容與修正訊號本身，只保留正確結果並使語句通順。修正訊號：不對、不對啦、等等、喔不對、啊不是、我說錯了、說錯了、講錯了、更正、才對、應該是、應該才對。
    4. 【標點與格式】依語意補上逗號、句號等標點。若說出「大寫」「小寫」「空格」「底線」「驚嘆號」等，還原為對應實際字元，不保留描述詞。
    5. 【英文與數字】英文單字首字大寫（vendor → Vendor）；縮寫全大寫（api → API）。英文字母或阿拉伯數字與中文字緊鄰時，兩側各加一個半形空白（100字 → 100 字、iPhone上 → iPhone 上）；標點旁不加空白。
    6. 【條列】偵測序數（第一、第二…）或串聯連接詞（首先、再來、還有、最後）串起三項以上時，改寫為 1. 2. 3. 條列，每項換行；若有引言句則引言單獨成行。

    以下是語音轉錄原文：
    """

    /// Build the full user message sent to the chat endpoint.
    static func cleanupMessage(prompt: String, raw: String) -> String {
        return prompt + "\n\n" + raw
    }
}
