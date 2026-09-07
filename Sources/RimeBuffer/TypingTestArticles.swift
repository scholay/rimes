import Foundation

enum TypingTestLanguage: String, Codable, CaseIterable {
    case chinese, english
    var displayName: String { self == .chinese ? "中文" : "English" }
    var speedUnit: String { self == .chinese ? "字/分" : "WPM" }
}

struct TypingTestArticle: Equatable, Identifiable {
    let id: String
    let version: Int
    let language: TypingTestLanguage
    let title: String
    let theme: String
    let difficulty: String
    let text: String

    var characterCount: Int { text.count }
    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
    var displayLength: String {
        language == .chinese ? "\(characterCount) 字" : "\(wordCount) words"
    }
}

/// Original practice prose written for this project, not copied from a corpus.
/// IDs and revisions are immutable scoring identities; changing prose requires
/// a version bump so results from different texts are never compared as peers.
enum TypingTestArticles {
    static var defaultArticle: TypingTestArticle { all[0] }
    static func article(id: String) -> TypingTestArticle? { all.first { $0.id == id } }

    static let all: [TypingTestArticle] = [
        .init(id: "rimes.morning-street", version: 1, language: .chinese,
              title: "清晨的街道", theme: "日常生活", difficulty: "轻松", text: [
            "天刚亮，街角的早餐店已经开门。老板把热气腾腾的豆浆放在柜台上，又将刚出锅的包子装进竹篮。赶早班的人快步走来，熟悉的客人只需点点头，店员就知道他今天想吃什么。我在靠窗的位置坐下，看见阳光慢慢爬上对面的屋顶，昨夜留下的雨水还在树叶上闪着光。",
            "一位老人牵着小狗经过。小狗对每一片落叶都很好奇，走几步便停下来闻一闻。老人并不催促，只在路口等它跟上。骑车送货的年轻人按了一下铃，大家便自然地让开一点。街道不算宽，却容得下各种各样的脚步，每个人都在自己的节奏里开始新的一天。",
            "吃完早餐，我决定绕一段路去车站。巷子深处有一家小花店，门前摆着新到的鲜花。店主正在给花换水，见我停下，便笑着说今天的天气适合散步。我没有买花，却记住了那几朵淡黄色的小花。它们让这条每天经过的路，看起来有了一点不同。",
            "到车站时，下一班车还要等几分钟。我收起手机，听远处的车声和近处的鸟鸣。过去总觉得早晨只属于匆忙，今天才发现，普通生活里也有很多值得停留的瞬间。不必特意寻找风景，只要愿意慢一点，认真看看身边的人和事，平常的一天也能有一个温暖的开头。"
        ].joined()),
        .init(id: "rimes.rainy-park", version: 1, language: .chinese,
              title: "雨后的公园", theme: "自然散文", difficulty: "轻松", text: [
            "午后的雨停了，云层之间透出一小片蓝天。我推开窗，闻到泥土和青草混在一起的气味，便换上鞋去附近的公园走走。石板路上积着浅浅的水，倒映着树枝和天空。风吹过时，水面轻轻晃动，眼前的影子也跟着散开，又慢慢聚在一起，像一幅不断变化的小画。",
            "草地边的长椅还没有干，几只麻雀却已经开始忙碌。它们在树下跳来跳去，偶尔低头啄几下，再迅速飞到高处。一个孩子蹲在路旁看蜗牛，认真地向妈妈解释它为什么走得这么慢。妈妈没有急着给出答案，而是陪他等了一会儿，直到蜗牛爬过一片湿润的叶子。",
            "沿着湖边继续走，远处的楼房被雨洗得格外清楚。水里的荷叶托着几颗圆圆的水珠，一只小鸟停在栏杆上，抖了抖翅膀。这样的景象其实并不少见，只是平时经过这里，我总想着还没完成的事情，很少留意一片叶子的颜色，或者一阵风从哪个方向吹来。",
            "走到出口时，太阳已经从云后出来。几个跑步的人迎面而过，鞋底在路上发出有节奏的轻响。我忽然觉得，休息不一定要安排一场远行，也不一定需要特别的理由。给自己留出一点没有任务的时间，看看天空，听听水声，心里的事情也会像雨后的空气一样，逐渐变得清楚。"
        ].joined()),
        .init(id: "rimes.short-trip", version: 1, language: .chinese,
              title: "一次短途旅行", theme: "旅行见闻", difficulty: "标准", text: [
            "周末，我们坐早班车去了附近的一座小城。没有排满行程，也没有列出必须去的景点，只带了水、雨伞和一本空白的笔记。车窗外的楼房渐渐变少，田野和山坡交替出现。同行的朋友指着远处的一条河说，小时候他常在这样的地方玩耍，一待就是整个下午。",
            "到站后，我们先找了一家普通的面馆。老板听说我们第一次来，便推荐了当地人常吃的口味，还告诉我们老街怎么走。面端上来时，汤很清，香气却很足。邻桌的人一边吃饭一边聊家常，声音不高，也没人急着离开。我们就这样慢慢吃完了午饭，感觉旅途真正开始了。",
            "老街两旁有修鞋铺、书店和杂货店。许多招牌已经有些旧了，门前却收拾得十分整齐。在一家书店里，我翻到一本介绍当地桥梁的小册子。店主说，桥不仅连接两岸，也留下了人们来往的故事。我们按照书里的路线找到河边，看见几位老人正坐在桥下乘凉。",
            "傍晚回程时，背包里只多了几张明信片，笔记本却写满了零碎的发现。有好吃的一碗面，有陌生人的一句指路，也有河面上缓缓移动的晚霞。这次旅行没有什么惊险的情节，但每次想起，心情都会轻快一点。原来离开熟悉的地方半天，就足以提醒我们，世界还有许多值得认真看看的角落。"
        ].joined()),
        .init(id: "rimes.library-day", version: 1, language: .chinese,
              title: "图书馆的一天", theme: "校园阅读", difficulty: "标准", text: [
            "新学期开始后，我给自己定了一个小计划：每周去一次图书馆，不为了考试，也不急着完成作业，只读一点真正感兴趣的内容。第一次去的时候，我在书架之间转了很久。书的种类太多，反而不知道从哪里开始。最后，我随手拿起一本介绍植物的书，坐到了窗边。",
            "书里写着许多平时没有注意过的事情。路旁常见的树为什么在不同季节换叶，种子怎样借着风旅行，一朵小花又如何吸引昆虫。我一边读，一边想起上学路上的那排树。原来每天都能见到的东西，也藏着这么多问题。读书有时不是获得一个答案，而是开始提出新的问题。",
            "中午，阳光照到桌面上，身旁的同学轻轻合上笔记本。我们在休息区聊了几句，发现他正在准备一个关于城市鸟类的小报告。他说，观察需要耐心，记录比记忆可靠。我把这句话写在书签背面，也决定下次经过校园的花园时，多停留几分钟，记下自己看到的变化。",
            "离开前，我借走了那本书，还挑了一本短篇故事。管理员提醒我注意归还日期，我认真记进日历。走出大门时，校园依旧热闹，但我的目光已经有些不同。树叶不再只是一片绿色，鸟鸣也不再只是背景里的声音。一段安静的阅读，让原本熟悉的世界重新变得生动，也让我更期待下一次来到这里。"
        ].joined()),
        .init(id: "rimes.small-task", version: 1, language: .chinese,
              title: "把一件小事做好", theme: "工作学习", difficulty: "标准", text: [
            "整理书桌原本是一件很小的事，我却拖了好几天。桌上堆着看过的资料、没写完的便条和几支找不到笔帽的笔。每次准备做事，总要先花时间寻找需要的东西。今天早上，我决定不再等一个特别空闲的时刻，而是给自己留出二十分钟，从最容易处理的一角开始。",
            "我先把东西分成三类：继续使用的，暂时保存的，还有可以清理的。常用的笔放在手边，重要资料装进文件夹，零散想法则统一记在一本小册子里。做完这些，桌面没有变得像照片里那样完美，却已经足够清楚。我坐下来时，终于不用先把一摞纸移到另一个地方。",
            "这件小事让我想到，很多计划难以开始，并不是因为我们缺少能力，而是把第一步想得太大。想学一门新知识，可以先读懂一页；想养成运动习惯，可以先走一小段路。开始之后再调整方法，比一直等待准备充分更有帮助。当然，遇到困难时也不必责怪自己，停下来看看哪里需要改变就好。",
            "晚上回到书桌前，我花两分钟把用过的东西放回原处。原来保持秩序并不总需要很强的意志，有时只是需要一个简单、顺手的办法。把一件小事做好，不会立刻改变全部生活，却能让下一件事容易一点。一天结束时，看见自己留下的一点进步，也是一种踏实而安静的快乐。"
        ].joined()),
        .init(id: "rimes.digital-day", version: 1, language: .chinese,
              title: "数字生活的小习惯", theme: "科技生活", difficulty: "进阶", text: [
            "手机和电脑让很多事情变得方便，但方便并不等于轻松。消息不断出现，文件越存越多，我们常常忙了一整天，却想不起真正完成了什么。上周，我尝试给数字生活做一次简单整理，不追求复杂的方法，只希望工具能更好地服务日常工作，而不是一直打断注意力。",
            "第一步是关闭不必要的提醒。我保留家人和重要工作的通知，把其他应用设为需要时再查看。第二步是整理文件夹，用“日期加主题”的方式命名资料。例如，9月7日的会议记录就放在当月目录中，相关图片放在同一位置。这样过一段时间再找，也不用依靠模糊的记忆。",
            "我还给自己留了两个固定的消息处理时段：上午10点和下午4点。并不是所有事情都能等到那个时候，紧急联系依然保持畅通，但大多数普通消息可以集中回复。开始时我有些不习惯，总想伸手点开屏幕。几天以后，才发现专心做完一件事，往往比同时追着许多提醒更有效率。",
            "整理之后，我没有多出神奇的时间，也没有马上改掉所有习惯。不过，桌面上的文件更容易找到，工作时的打断少了一些，睡前也能安心放下手机。技术的价值不只在于更快、更强，还在于让人拥有清楚的选择。适合自己的规则可以很小，只要能持续使用，就能慢慢带来真实而稳定的改变。"
        ].joined()),
        .init(id: "rimes.english-morning", version: 1, language: .english,
              title: "A Quiet Morning", theme: "Daily life", difficulty: "Easy", text:
            "On Saturday morning, I walked to a small bakery near my home. The street was still quiet, and a cool breeze moved through the trees. Inside the shop, the baker was placing fresh bread on a wooden shelf. I bought a warm roll and a cup of tea, then sat at a table by the window. A woman outside stopped to help a child tie a shoe. Two neighbors waved to each other across the road. Nothing unusual happened, but I enjoyed watching the town wake up. Usually, I would have checked my phone while waiting for the tea to cool. This time, I left it in my pocket. I noticed the soft light on the table and the sound of cups behind the counter. Before leaving, I wrote a short note in my book: a good day does not always need a big plan. Sometimes, it begins with a simple walk and enough time to notice the world around us."),
        .init(id: "rimes.english-journey", version: 1, language: .english,
              title: "The Journey Home", theme: "Travel", difficulty: "Standard", text:
            "Our train left the city just before sunset. After a busy weekend, my friend and I were glad to sit down and watch the fields pass outside. We had visited a museum, found a tiny bookshop, and spent an afternoon walking beside the river. The most memorable part of the trip, however, was a conversation with a local gardener. She showed us a path behind the old station and explained how the neighborhood had changed. When we reached the end of the path, we found a garden full of yellow flowers. Families were sitting on benches, and children were drawing pictures on a long sheet of paper. We stayed until the light began to fade. On the train, I looked at the few photographs I had taken. They could not capture every sound or feeling, but they helped me remember. Next time, we agreed, we would leave more room in our schedule for places we had not planned to see.")
    ]
}
