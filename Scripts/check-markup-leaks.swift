// Proves that no markup a model writes can reach a reader.
//
// Every renderer in this app has a fallback, and the one fallback that is never
// allowed is "print the source". A paragraph that comes back reading
// `\left\lfloor\frac{n-1}{2}\right\rfloor players remain` has to be *set*, not
// echoed — and the way to know that stays true is to check it mechanically
// rather than to look at screenshots after each change.
//
// Run:
//   Scripts/check-markup-leaks.sh [extra.md …]
//
// Any file given on the command line is split into paragraphs and added to the
// corpus, so a document that ever renders badly can be added to it and stay
// covered from then on.

import Foundation

/// What a reader would end up seeing, taking the *worst* path through the
/// renderers: the one where nothing can be drawn and everything falls through
/// to characters.
func rendered(_ paragraph: String) -> String {
    MathInlineSplitter.split(paragraph).map { segment in
        switch segment {
        case let .prose(text): return text
        case let .math(latex): return MathLinearizer.text(for: latex)
        }
    }.joined()
}

/// Markup: a LaTeX command, a maths delimiter, or a `$…$` pair whose contents
/// were maths and should therefore have been set as maths.
func leak(in output: String) -> String? {
    let markup = try! NSRegularExpression(pattern: #"\\[A-Za-z]+|\\\[|\\\]|\\\(|\\\)|\$\$"#)
    let range = NSRange(output.startIndex..., in: output)
    if let match = markup.firstMatch(in: output, range: range),
       let found = Range(match.range, in: output) {
        return String(output[found])
    }
    let dollars = try! NSRegularExpression(pattern: #"\$([^$\n]{1,40})\$"#)
    if let match = dollars.firstMatch(in: output, range: range),
       let body = Range(match.range(at: 1), in: output),
       MathParser.looksLikeMath(String(output[body])) {
        return "$\(output[body])$"
    }
    return nil
}

var corpus: [String] = [
    // Real output, from documents this app produced.
    #"Returning to the original game, note that after one complete round, \left\lfloor\frac{n-1}{2}\right\rfloor players remain."#,
    #"A-3 Note that the series on the left is simply \exp(-x^{2}/2). By integration by parts,"#,
    #"\[\angle HBC=\pi/2-\angle C=\angle CAF),\]"#,
    #"$\[k\geq2.\]$"#,
    #"\int_{0}^{\infty}x^{2n+1}e^{-x^{2}/2}d x=2n\int_{0}^{\infty}x^{2n-1}e^{-x^{2}/2}d x"#,
    #"\sum_{n=0}^{\infty}\frac{1}{2^{n}n!}=\sqrt{e}."#,
    #"\phi\left(x\right)\phi\left(y\right)\phi\left(y^{-1}x^{-1}\right)=\phi(e)\phi(x y)"#,
    #"\frac{f^{\prime}(t)}{f(t)}=\frac{n-1-r}{1+t}-\frac{r}{1-t}"#,
    // Structures.
    #"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"#,
    #"f(x) = \begin{cases} 1 & x>0 \\ 0 & x\le 0 \end{cases}"#,
    #"\begin{array}{cc} 1 & 2 \\ 3 & 4 \end{array}"#,
    #"\binom{n}{k} = \frac{n!}{k!(n-k)!}"#,
    // Decoration, alphabets, units.
    #"\vec{v} \cdot \hat{n} = \|\vec{v}\|\cos\theta"#,
    #"\overline{AB} \perp \widehat{CD}, \dot{x} = \ddot{y}"#,
    #"设 $\mathbb{R}$ 上的函数 $f$ 满足 \mathcal{L}(f) = \mathfrak{g}"#,
    #"温度为 $25\,^\circ\mathrm{C}$ 时，$\rho=1.0\times10^{3}\,\mathrm{kg/m^3}$"#,
    #"\text{if } x > 0 \text{, then } \mathrm{sgn}(x)=1"#,
    #"\lim_{x \to 0} \frac{\sin x}{x} = 1 \quad \text{and} \quad \alpha\leq\beta"#,
    #"a \equiv b \pmod{n}, \gcd(a,b)=1"#,
    #"\tag{3.57} f_{d_1,i} = \frac{f_{c,i}(v_{k-1,i})}{\Delta t}"#,
    // Commands nothing here has ever heard of.
    #"\weirdcommand{x} and \anotherone"#,
    #"\left( \frac{1}{2} \right)^{n} \leq \alpha\beta"#,
    // Things that are not maths and must survive as they are.
    "cost $2 per square foot, the wood $10 per square foot",
    "plain prose with no maths at all",
    "",
]

for path in CommandLine.arguments.dropFirst() {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("跳过读不到的文件：\(path)")
        continue
    }
    corpus += text.components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

var failures = 0
for source in corpus {
    let output = rendered(source)
    if let found = leak(in: output) {
        failures += 1
        print("泄漏 «\(found)»\n  原文：\(source.prefix(100))\n  渲染：\(output.prefix(100))")
    }
}

if failures == 0 {
    print("通过：语料 \(corpus.count) 条，没有任何 LaTeX 命令或分隔符出现在读者看到的文字里")
    exit(0)
}
print("失败：\(failures)/\(corpus.count)")
exit(1)
