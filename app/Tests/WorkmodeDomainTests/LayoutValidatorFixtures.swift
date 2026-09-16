import WorkmodeDomain

// LayoutValidatorTests 拆成三個檔（地點層／profile 層／樹節點）之後，這些 fixture
// 三邊都要用，所以搬到這裡。它們不是通用工具——每一支都只服務 validate 的測試，
// 而且形狀綁著 workmode.sh 的檢查順序。
//
// 全部用 JSONValue 直接建設定，不經 parser：這一層是純規則，不該依賴解析。

/// 用 JSONValue 直接建設定，不經 parser——這一層是純規則，不該依賴解析。
let okProfiles = obj([("P", obj([("trees", .object([]))]))])

/// 欄位齊全（desc／displays.main／windows 都在）的地點。
func healthyLocation(profiles: JSONValue? = okProfiles,
                     extra: [(String, JSONValue)] = []) -> JSONValue
{
    var members: [(String, JSONValue)] = [
        ("desc", .string("x")),
        ("displays", obj([("main", .string("M"))])),
        ("windows", .array([])),
    ]
    if let profiles {
        members.append(("profiles", profiles))
    }
    return obj(members + extra)
}

let okProfile = obj([("trees", .object([]))])

/// 只有一個 profile 的健康地點。profile 那四條的 fixture 全部從這裡疊。
func locationWith(profile name: String,
                  _ value: JSONValue,
                  windows: JSONValue = .array([])) -> JSONValue
{
    obj([("desc", .string("x")),
         ("displays", obj([("main", .string("M"))])),
         ("windows", windows),
         ("profiles", obj([(name, value)]))])
}

/// 把 label 清單包成 windows 陣列。
func windowList(_ labels: [JSONValue]) -> JSONValue {
    .array(labels.map { obj([("label", $0)]) })
}

/// 哨兵：名稱含空白的合法地點。它的違規有沒有印出來，就是串流有沒有繼續。
func withSentinel(_ first: JSONValue,
                  extraTop: [(String, JSONValue)] = []) -> JSONValue
{
    obj(extraTop + [("aaa", first), ("z z", healthyLocation())])
}

let sentinelProblem = LayoutProblem.structural("地點名稱「z z」不能含空白")

/// trees 整份由呼叫端給——型別那幾條需要非物件的 trees。
func treeConfigRaw(_ trees: JSONValue, windows: JSONValue = .array([])) -> JSONValue {
    withSentinel(locationWith(profile: "P", obj([("trees", trees)]), windows: windows))
}

/// 單一角色 main 的樹。路徑前綴固定是 aaa.P.trees.main。
func treeConfig(_ node: JSONValue, windows: JSONValue = .array([])) -> JSONValue {
    treeConfigRaw(obj([("main", node)]), windows: windows)
}
