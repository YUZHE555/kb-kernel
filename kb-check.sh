#!/usr/bin/env bash
# kb-check.sh —— 知识库体检  v3.27（39 项）
# 用法：在项目根执行   bash kb-check.sh            （默认库根 ./kb）
#                      bash kb-check.sh 某目录/kb  （指定库根）
# 只读，不改任何文件。分「错 / 提示」两档报，分开计数。

KB=""
case "${1:-}" in
  --list|-l) LIST_ONLY=1 ;;
  *) KB="${1:-kb}" ;;
esac

# ============ 守卫：库根不对就直接退出，绝不给"干净的 0" ============
# 这是最坏的一种假绿：路径打错一个字母，脚本照样印「错：0 / exit 0」，
# 人就会以为库是健康的——而它一个页都没扫。
if [ -z "${LIST_ONLY:-}" ]; then
  if [ ! -d "$KB" ]; then
    printf '库根不存在：%s\n' "$KB"
    printf '什么都还没查，别把这次结果当结论。\n'
    exit 3
  fi
  if [ ! -d "$KB/pages" ]; then
    printf '库根在，但没有 %s/pages/ ——这不是知识库结构（四件套缺件）\n' "$KB"
    printf '什么都没查，别把这次结果当结论。\n'
    exit 3
  fi
fi

# ============ 清单：唯一真相源 ============
# 文档里的 Lint 表是本清单的副本。改这里，就要同步改文档；跑 --list 一对就知道有没有漂移。
CHECKS=(
 "集合比对：pages/ 里的页 vs 索引登记的页，逐行比（不去重、箭头目标不取）"
 "同一页被登记两次（主索引与分片各登记一次）"
 "域清单列的分片文件不存在"
 "分片反向失联：INDEX-*.md 不在主索引的域清单里"
 "页缺 status / status 非法"
 "页缺 updated"
 "draft 页缺 draft_since"
 "提示：draft_since 距今天超过 30 天（处置三选一：重核 / 转正 / 继续挂；挂要记 复核: 日期）"
 "单页正文超 500 字（supersedes 非空的整合页放宽 800）"
 "source 指向 raw/ 里不存在的文件"
 "superseded_by 指向不存在的页"
 "supersedes 指向不存在的页"
 "conflicts_with 指向不存在的页"
 "conflicts_with 只填了单边（A 指 B，B 没回指）"
 "supersedes 只填了单边（A 取代 B，B 没用 superseded_by 回指；反向同理）"
 "## 已取代 里混进了没有 superseded_by 的活行"
 "superseded_by 非空的页却还在活行区（没进 ## 已取代 降级）"
 "主 INDEX.md 活行超过 40 条"
 "分片页级行超过 40 条"
 "raw/ 单个文件超过 8000 字"
 "热层超过 5 行"
 "热层指向不存在的文件（空指针）"
 "提示：raw/ 里有文件但缺同名 .md 说明"
 "提示：N 页 source 写「来自对话」而 raw/ 为空（计数式，共 M 页 source 为对话）"
 "提示：stable 的 updated 超过 180 天没动"
 "索引页级行必须四段（路径 | 一句话 | 状态 | 日期）"
 "索引摘要超过 20 字"
 "页名带日期前缀 / 编号 / 版本号"
 "raw/ 文件名没带日期"
 "stable 页残留 draft_since"
 "已取代死行末尾没有 → pages/<页>.md"
 "域清单行写了页数"
 "页正文里没有指向同目录的 .md 引用"
 "提示：库根有白名单外的文件（INDEX.md / INDEX-*.md / LOG.md / pages / raw 之外）"
 "提示：raw/ 里的原件没有任何一页 source 指向它（可能是暂存，也可能是入库没做完）"
 "四件套齐全：kb/INDEX.md、kb/LOG.md 都在（LOG 空着只提示，不算错）"
 "已取代死行的箭头目标必须存在，且等于该页的 superseded_by"
 "提示：conflicts_with 两端都填了，但已挂超过 30 天没人裁决"
 "提示：某页 ## 补充 攒到 3 条，该整合（新建一页重写、supersedes 指旧页）"
)
TOTAL=${#CHECKS[@]}          # 项数不许手写：由清单长度算出来

if [ -n "${LIST_ONLY:-}" ]; then
  echo "本脚本声明执行 $TOTAL 项："
  i=0; for c in "${CHECKS[@]}"; do i=$((i+1)); printf '%2d. %s\n' "$i" "$c"; done
  exit 0
fi

E=(); W=()          # 错 / 提示
SKIP=0; SKIPNOTE=""
NA=0; NANOTE=""
addE(){ E+=("$1"); }
addW(){ W+=("$1"); }

# ---------- 小工具 ----------
idx_files(){ for f in "$KB"/INDEX.md "$KB"/INDEX-*.md; do [ -f "$f" ] || continue; [ "$f" = "$KB/INDEX-*.md" ] && continue; echo "$f"; done; }

# 索引里的页级行：输出  kind<TAB>页名<TAB>整行   kind=0 活行 / 1 已取代死行
# 按 | 切段，不按空白切——页名里可以有空格，切错了会连锁误报
idx_rows(){ awk -F'|' '/^## 已取代/{d=1;next} /^pages\//{k=d?"1":"0"; p=$1; gsub(/^[ \t]+|[ \t]+$/,"",p); sub(/^pages\//,"",p); sub(/\.md$/,"",p); print k"\t"p"\t"$0}' "$1"; }

# frontmatter 取字段（只在前两个 --- 之间找）
fm(){ awk -v k="$1" '/^---$/{n++;next} n==1{ if (index($0,k":")==1){ v=$0; sub("^"k":","",v); sub(/#.*/,"",v); gsub(/^[ \t]+|[ \t]+$/,"",v); print v; exit } }' "$2"; }

# 关系字段允许多值：逗号 / 顿号 / 中文逗号分隔，逐项去空，每行一个名字
# 可传参，也可从管道 stdin 读
split_names(){ local v; v=${1:-$(cat)}; printf '%s' "$v" | sed 's/[，、,]/\n/g' | sed 's/^[ \t]*//;s/[ \t]*$//' | grep -v '^$'; }

# 字符数——不依赖 locale。
# UTF-8 的续字节是 0x80-0xBF；把它们全删掉，每个字符（无论中英）正好剩 1 字节。
# 这样在 C locale（Android shell 默认）下也是"字"数，不是"字节"数。
charlen(){ tr -d '\n\200-\277' | wc -c | tr -d ' '; }

# 自检：一个汉字必须算 1
if [ "$(printf '中' | charlen)" = "1" ]; then UTF8_OK=1; else UTF8_OK=0; fi

# 正文汉字级字符数（扣掉 frontmatter）
# 页尾那行"见 x.md"是固定成本的一行，不计入 500 字预算——否则 493 字的内容也会被判超
body_chars(){
  if head -1 "$1" | grep -q '^---$'; then awk '/^---$/{n++;next} n>=2{print}' "$1"; else cat "$1"; fi \
  | awk '{ if ($0 ~ /^[[:space:]]*(\[[^]]*\]\([^)]*\.md\)|[^ \t]*\.md)[[:space:]]*$/) next; print }' \
  | tr -d ' \t' | charlen
}

# ---------- 1. 集合比对：pages/ 里的页 vs 索引登记的页 ----------
# 两边排序后逐行比；不去重（重复项本身就是缺陷）；箭头目标不取（取每行第一字段）
A_SET=$(ls "$KB/pages/" 2>/dev/null | grep '\.md$' | sed 's/\.md$//' | sort)
B_SET=$(for f in $(idx_files); do idx_rows "$f"; done | awk -F'\t' '{print $2}' | sed 's/\.md$//' | sort)
if [ "$A_SET" != "$B_SET" ]; then
  DL=()
  while IFS= read -r l; do DL+=("$l"); done < <(diff <(printf '%s\n' "$A_SET") <(printf '%s\n' "$B_SET") | grep '^[<>]')
  addE "页文件与索引登记对不上（< 只在 pages/ / > 只在索引里）：$(printf '%s ' "${DL[@]}" | sed 's/[<>] //g')"
fi

# ---------- 2. 同一页被登记两次 ----------
DUP=$(for f in $(idx_files); do idx_rows "$f"; done | awk -F'\t' '{print $2}' | sed 's/\.md$//' | sort | uniq -d)
[ -n "$DUP" ] && addE "同一页登记了不止一次：$(echo $DUP | tr '\n' ' ')"

# ---------- 3a. 域清单列的分片文件不存在（正向） ----------
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$KB/$f" ] || addE "主 INDEX.md 的域清单里列了 $f，但文件不存在（那片页已经失联）"
done < <(grep -o 'INDEX-[^[:space:]（）()，。、]*\.md' "$KB/INDEX.md" 2>/dev/null | sort -u)

# ---------- 3. 分片反向失联 ----------
for f in "$KB"/INDEX-*.md; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  grep -q -- "$base" "$KB/INDEX.md" 2>/dev/null || addE "分片 $base 在主 INDEX.md 里没有域清单行（整片页会永久失联）"
done

# ---------- 4~6. 每页 frontmatter / 字数 / 超期 ----------
PAGE_N=$(ls "$KB/pages/" 2>/dev/null | grep -c '\.md$')
TODAY=$(date +%s 2>/dev/null) || TODAY=""
DATEOK=1
# Android/toybox 的 date 可能不支持 -d，失败时不许静默跳过
to_sec(){ sec=$(date -d "$1" +%s 2>/dev/null) || sec=""; [ -z "$sec" ] && DATEOK=0; printf '%s' "$sec"; }
for p in "$KB"/pages/*.md; do
  [ -f "$p" ] || continue
  name=$(basename "$p" .md)
  st=$(fm status "$p"); up=$(fm updated "$p"); ds=$(fm draft_since "$p"); sb=$(fm superseded_by "$p"); sp=$(fm supersedes "$p")
  [ -z "$st" ] && addE "$name：缺 status"
  case "$st" in
    stable|draft) ;;
    "") ;;
    *) addE "$name：status 只能是 stable / draft，现在是「$st」" ;;
  esac
  [ -z "$up" ] && addE "$name：缺 updated"
  if [ "$st" = "draft" ]; then
    [ -z "$ds" ] && addE "$name：draft 页缺 draft_since"
    if [ -n "$ds" ]; then
      sec=$(to_sec "$ds")
      if [ -n "$sec" ]; then
        age=$(( (TODAY - sec) / 86400 ))
        # 「继续挂」必须留下复核行，否则提示永远亮：复核: YYYY-MM-DD，仍待确认（原因）
        rv=$(grep -o '复核[:：][^0-9]*[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' "$p" 2>/dev/null | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' | tail -1)
        if [ -n "$rv" ]; then
          sec2=$(to_sec "$rv"); age2=$(( (TODAY - sec2) / 86400 ))
          [ "$age2" -gt 30 ] && addW "$name：draft 已 $age 天，上次复核 $rv 又过 $age2 天，仍未转正（该重核了）"
        else
          [ "$age" -gt 30 ] && addW "$name：draft 已 $age 天未转正（超 30 天，处置三选一：重核 / 转正 / 继续挂；继续挂要在页里记一行 复核: 日期）"
        fi
      fi
    fi
  fi
  limit=500; [ -n "$sp" ] && limit=800
  n=$(body_chars "$p"); [ "$n" -gt "$limit" ] && addE "$name：正文 $n 字，超 $limit"
  if [ -n "$sb" ]; then
    case "$sb" in
      *.md) addE "$name：frontmatter 引用带了扩展名（superseded_by: $sb）——这里写裸页名，不带 .md" ;;
      *) [ -f "$KB/pages/$sb.md" ] || addE "$name：superseded_by 指向不存在的页「$sb」" ;;
    esac
  fi
  if [ -n "$sp" ]; then
    case "$sp" in
      *.md) addE "$name：frontmatter 引用带了扩展名（supersedes: $sp）——这里写裸页名，不带 .md" ;;
      *) while IFS= read -r t; do
           [ -z "$t" ] && continue
           [ -f "$KB/pages/$t.md" ] || addE "$name：supersedes 指向不存在的页「$t」"
         done < <(split_names "$sp") ;;
    esac
  fi
  cw=$(fm conflicts_with "$p")
  if [ -n "$cw" ]; then
    case "$cw" in
      *.md) addE "$name：frontmatter 引用带了扩展名（conflicts_with: $cw）——这里写裸页名，不带 .md" ;;
      *) [ -f "$KB/pages/$cw.md" ] || addE "$name：conflicts_with 指向不存在的页「$cw」" ;;
    esac
  fi
  # 180 天提示（只按 updated，不建反向链接表）
  if [ "$st" = "stable" ] && [ -n "$up" ]; then
    sec=$(to_sec "$up")
    if [ -n "$sec" ]; then
      age=$(( (TODAY - sec) / 86400 ))
      [ "$age" -gt 180 ] && addW "$name：stable 已 $age 天没动过（事实可能过期）"
    fi
  fi
done

# ---------- 7. 已取代小节里混进活行 ----------
while IFS= read -r p; do
  [ -z "$p" ] && continue
  sb=$(fm superseded_by "$KB/pages/$p.md" 2>/dev/null)
  [ -z "$sb" ] && addE "「## 已取代」里混进了没有 superseded_by 的活行：$p"
done < <(for f in $(idx_files); do idx_rows "$f"; done | awk -F'\t' '$1=="1"{print $2}')

# ---------- 7b. 死行箭头：目标必须存在，且必须等于该页的 superseded_by ----------
while IFS=$'\t' read -r pname arrow; do
  [ -z "$pname" ] && continue
  tgt=${arrow%.md}
  if [ ! -f "$KB/pages/$tgt.md" ]; then
    addE "$pname：死行箭头指向不存在的页「$tgt」（留痕指向了空气）"
  else
    sb=$(fm superseded_by "$KB/pages/$pname.md" 2>/dev/null)
    [ -n "$sb" ] && [ "$sb" != "$tgt" ] && addE "$pname：死行箭头指向「$tgt」，但 frontmatter 是「$sb」——两处留痕不一致"
  fi
done < <(for f in $(idx_files); do
  awk -F'|' '/^## 已取代/{d=1;next} d && $0 ~ /^pages\//{ if (match($0, /→[ ]*pages\/[^ \t]*\.md/)) { a=substr($0, RSTART, RLENGTH); sub(/^→[ ]*pages\//,"",a); sub(/\.md$/,"",a); p=$1; gsub(/^[ \t]+|[ \t]+$/,"",p); sub(/^pages\//,"",p); sub(/\.md$/,"",p); print p"\t"a } }' "$f"
done)

# ---------- 7d. A4：superseded_by 非空的页必须已降级进 ## 已取代 ----------
# 反向于第 7 项：第 7 项抓"死节里混进活行"，这项抓"挂了被取代、却还留在活行区"。
# 只填字段不降级：旧页仍占 40 额度、仍会被 Query 命中，两个冲突说法同时可检索。
DEAD_SET=$(for f in $(idx_files); do idx_rows "$f"; done | awk -F'\t' '$1=="1"{print $2}' | sed 's/\.md$//' | sort -u)
for p in "$KB"/pages/*.md; do
  [ -f "$p" ] || continue
  name=$(basename "$p" .md)
  sb=$(fm superseded_by "$p")
  [ -z "$sb" ] && continue
  printf '%s\n' "$DEAD_SET" | grep -qxF "$name" \
    || addE "$name：superseded_by 非空，但页行还在活行区——被取代的页必须进 ## 已取代 并带箭头回指"
done

# ---------- 7c. 补充节攒到 3 条 → 该整合 ----------
for p in "$KB"/pages/*.md; do
  [ -f "$p" ] || continue
  n=$(grep -cE '^#*[ \t]*补充([（(]|[ \t]*$)' "$p" 2>/dev/null | tr -d ' ')
  [ "${n:-0}" -ge 3 ] && addW "$(basename "$p" .md)：## 补充 已攒 $n 条，头部已不代表整页——该整合（新建一页重写正文+补充，supersedes 指旧页）"
done

# ---------- 8. conflicts_with 单边 ----------
for p in "$KB"/pages/*.md; do
  [ -f "$p" ] || continue
  cw=$(fm conflicts_with "$p")
  [ -z "$cw" ] && continue
  [ ! -f "$KB/pages/$cw.md" ] && continue
  # 冲突两端都填了，却一直挂着没人裁决：拿该页 updated 当挂起起点
  up=$(fm updated "$p")
  if [ -n "$up" ] && [ -n "$TODAY" ]; then
    sec=$(to_sec "$up")
    if [ -n "$sec" ] && [ $(( (TODAY - sec) / 86400 )) -gt 30 ]; then
      if [ -z "${CFW_W:-}" ]; then
        addW "$(basename "$p" .md)：冲突（与「$cw」）挂了 $(( (TODAY - sec) / 86400 )) 天还没裁决，两端都填了 conflicts_with 却没人定"
        CFW_W=1
      fi
    fi
  fi
  back=$(fm conflicts_with "$KB/pages/$cw.md")
  [ "$back" != "$(basename "$p" .md)" ] && addE "$(basename "$p" .md)：conflicts_with 单边——「$cw」没有回指它"
done

# ---------- 8b. supersedes 单边：A.supersedes:B ⟺ B.superseded_by:A ----------
# 取代链必须双向留痕：只填一头，审计时查不回去（与 conflicts_with 单边同型）。
# 幽灵目标已由存在性项报，这里跳过不存在的页，不重复喊。
rel_back_has(){ # $1=对方页文件  $2=本页名  $3=回指字段名
  fm "$3" "$1" | split_names | grep -qxF "$2"
}
for p in "$KB"/pages/*.md; do
  [ -f "$p" ] || continue
  name=$(basename "$p" .md)
  sp=$(fm supersedes "$p")
  [ -z "$sp" ] && continue
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    [ ! -f "$KB/pages/$t.md" ] && continue
    rel_back_has "$KB/pages/$t.md" "$name" "superseded_by" \
      || addE "$name：supersedes 单边——「$t」没有用 superseded_by 回指它"
  done < <(split_names "$sp")
done
for p in "$KB"/pages/*.md; do
  [ -f "$p" ] || continue
  name=$(basename "$p" .md)
  sb=$(fm superseded_by "$p")
  [ -z "$sb" ] && continue
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    [ ! -f "$KB/pages/$t.md" ] && continue
    rel_back_has "$KB/pages/$t.md" "$name" "supersedes" \
      || addE "$name：superseded_by 单边——「$t」没有用 supersedes 回指它"
  done < <(split_names "$sb")
done

# ---------- 9~10. 索引容量 ----------
LIVE=$(idx_rows "$KB/INDEX.md" 2>/dev/null | awk -F'\t' '$1=="0"' | wc -l | tr -d ' ')
LIVE_ALL=$(for f in $(idx_files); do idx_rows "$f" 2>/dev/null; done | awk -F'\t' '$1=="0"' | wc -l | tr -d ' ')
SHARD_N=$(ls "$KB"/INDEX-*.md 2>/dev/null | wc -l | tr -d ' ')
[ "$LIVE" -gt 40 ] && addE "主 INDEX.md 活行 $LIVE 条，超 40，该拆分片"
for f in "$KB"/INDEX-*.md; do
  [ -f "$f" ] || continue
  n=$(idx_rows "$f" | awk -F'\t' '$1=="0"' | wc -l | tr -d ' ')
  [ "$n" -gt 40 ] && addE "分片 $(basename "$f") 活行 $n 条，超 40"
done

# ---------- 10b. source 指向 / 指错层 ----------
RAWCNT=$(ls -A "$KB/raw/" 2>/dev/null | wc -l | tr -d ' ')
DIALOG_ALL=0; DIALOG_EMPTY=0
for p in "$KB"/pages/*.md; do
  [ -f "$p" ] || continue
  name=$(basename "$p" .md)
  src=$(fm source "$p")
  [ -z "$src" ] && continue
  case "$src" in
    raw/*) f=$(printf '%s' "$src" | grep -o 'raw/.*\.md' | head -1)
           [ -z "$f" ] && f=${src%% *}     # 没 .md 时退回第一段
           [ -f "$KB/$f" ] || addE "$name：source 指向不存在的 raw 文件「$f」" ;;
  esac
  # 「来自对话」只看库里有没有任何 raw 原件。
  # 不能按「同日有没有 raw」判——那是日期邻近，不是同一份材料（实测假阳性）。
  # 计数式：N 页缺 raw（共 M 页 source 为对话）；去重只用于同一页重复，不抹平规模。
  if printf '%s' "$src" | grep -q '来自对话'; then
    DIALOG_ALL=$((DIALOG_ALL+1))
    [ "$RAWCNT" -eq 0 ] && DIALOG_EMPTY=$((DIALOG_EMPTY+1))
  fi
done
[ "$DIALOG_EMPTY" -gt 0 ] && addW "有 $DIALOG_EMPTY 页 source 写「来自对话」而 raw/ 为空（共 $DIALOG_ALL 页 source 为对话）——口述记录无从追溯"

# ---------- 11. raw 体积 ----------
for r in "$KB"/raw/*; do
  [ -f "$r" ] || continue
  case "$r" in *.md|*.txt) n=$(charlen < "$r"); [ "$n" -gt 8000 ] && addE "raw/$(basename "$r") 有 $n 字，超 8000，该切";;
             *) [ ! -f "$r.md" ] && addW "raw/$(basename "$r") 没有同名 .md 说明";;
  esac
done

# ---------- 11b. 四件套 ----------
[ -f "$KB/INDEX.md" ] || addE "缺 kb/INDEX.md（四件套不齐，索引没了什么都查不到）"
if [ ! -f "$KB/LOG.md" ]; then
  addE "缺 kb/LOG.md（四件套不齐，留痕全押在这个文件上）"
else
  LOGN=$(grep -c . "$KB/LOG.md" 2>/dev/null | tr -d ' ')
  head -1 "$KB/LOG.md" | grep -q '^#' || addE "LOG.md 首行不是标题，格式走偏了"
  [ "${LOGN:-0}" -le 1 ] && addW "LOG.md 只有标题、一条记录都没有（要么还没自举，要么从没留过痕）"
fi

# ---------- 12. 热层 ----------
AG="$(dirname "$KB")/AGENTS.md"
[ "$AG" = "/AGENTS.md" ] && AG="./AGENTS.md"
HOTPATH="$AG"
if [ ! -f "$AG" ]; then
  NA=$((NA+2)); NANOTE="${NANOTE}${NANOTE:+；}库旁无 AGENTS.md，热层两项不适用"
elif ! grep -q '^## 热层' "$AG"; then
  NA=$((NA+2)); NANOTE="${NANOTE}${NANOTE:+；}$AG 里没有 ## 热层 小节（文档允许的状态），两项不适用"
fi
HF=0; HR=0
if [ -f "$AG" ] && grep -q '^## 热层' "$AG"; then
  HOT=$(awk '/^## 热层/{f=1;next} /^#/{f=0} f&&NF' "$AG")
  HCNT=$(printf '%s\n' "$HOT" | grep -c .)
  [ "$HCNT" -gt 5 ] && addE "热层 $HCNT 行，超 5 行上限"
  while IFS= read -r ref; do
    case "$ref" in
      pages/*) real="$KB/$ref" ;;
      *)       real="$(dirname "$KB")/$ref" ;;
    esac
    HF=$((HF+1))
    [ -f "$real" ] || addE "热层指向不存在的文件：$ref（空指针）"
  done < <(printf '%s\n' "$HOT" | grep -oE '(kb|pages)/[^[:space:]]*\.md')
  HR=$(printf '%s\n' "$HOT" | grep -oE '(kb|pages)/[^[:space:]]*\.md' | while IFS= read -r ref; do
        case "$ref" in pages/*) real="$KB/$ref";; *) real="$(dirname "$KB")/$ref";; esac
        [ -f "$real" ] && echo x; done | wc -l | tr -d ' ')
  [ "$HF" -gt 0 ] && [ $((HR * 2)) -lt "$HF" ] && addW "热层 $HF 条指针里只有 $HR 条能在本库根解析——这份 $HOTPATH 可能有一部分是从别的库根抄来的"
fi

# ---------- 11. 索引行结构 / 摘要长度 / 死行箭头 ----------
while IFS= read -r line; do
  case "$line" in
    "SUM"*) f=${line#SUM	}; f=${f%%	*}; v=${line##*	}
            f=$(basename "$f")
            n=$(printf '%s' "$v" | charlen)
            [ "$n" -gt 20 ] && addE "$f：摘要 $n 字，超 20——索引退化成正文" ;;
    *) addE "$line" ;;
  esac
done < <(for f in $(idx_files); do
  awk -F'|' -v fn="$(basename "$f")" '
    /^## 已取代/{d=1;next}
    /^pages\//{
      if (NF!=4) { printf "%s：页级行只有 %d 段（应四段：路径 | 一句话 | 状态 | 日期）\n", fn, NF; next }
      if (d && $0 !~ /→[ \t]*pages\//) printf "%s：死行没带 → pages/<页>.md\n", fn
      s=$2; gsub(/^[ \t]+|[ \t]+$/,"",s); printf "SUM\t%s\t%s\n", fn, s
    }
  ' "$f"
done)

# ---------- 12. 页名 / raw 命名 / stable 残留 draft_since / 页尾链接 ----------
while IFS= read -r l; do addE "$l"; done < <(for f in $(idx_files); do
  awk '/INDEX-[^ \t]*\.md/{ if ($0 ~ /[0-9]+[ \t]*页|（[0-9]+[ \t]*页/) printf "%s：域清单行写了页数（没人维护的数字比没有更坏）\n", FILENAME }' "$f"
done)

for p in "$KB"/pages/*.md; do
  [ -f "$p" ] || continue
  name=$(basename "$p" .md)
  printf '%s' "$name" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}|^[0-9]+[-_]|-[vV][0-9]+$' \
    && addE "页名「$name」带日期前缀 / 编号 / 版本号（名字会漂）"
  st=$(fm status "$p"); ds=$(fm draft_since "$p")
  [ "$st" = "stable" ] && [ -n "$ds" ] && addE "$name：stable 页残留 draft_since（状态说谎，还会让 30 天检查误报）"
  last=$(awk '/^---$/{n++;next} n>=2&&NF{l=$0} END{print l}' "$p")
  if [ "$PAGE_N" -le 1 ]; then
    if [ -z "${ONE_W:-}" ]; then
      NA=$((NA+1)); NANOTE="${NANOTE}${NANOTE:+；}只有 1 页，无同目录页可链，页尾链接一项不适用"; ONE_W=1
    fi
  else
    body=$(awk '/^---$/{n++;next} n>=2' "$p")
    printf '%s' "$body" | grep -q '\.md' || addE "$name：正文里没有指向同目录 .md 的引用（跨页导航断了）"
  fi
done

for r in "$KB"/raw/*; do
  [ -f "$r" ] || continue
  base=$(basename "$r")
  printf '%s' "$base" | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || addE "raw/$base 文件名没带日期（出处不可追溯）"
done

# ---------- 13. 库根白名单 ----------
EXTRA=$(for e in "$KB"/*; do
  [ -e "$e" ] || continue
  b=$(basename "$e")
  case "$b" in
    INDEX.md|LOG.md|pages|raw|INDEX-*.md) ;;
    *) printf '%s ' "$b" ;;
  esac
done)
if [ -n "$EXTRA" ]; then
  addW "库根有白名单外的文件：$EXTRA（备份/杂物混在里面会污染全库 grep 的命中数）"
fi

# ---------- 14. raw 原件有没有被任何页引用 ----------
for r in "$KB"/raw/*.md; do
  [ -f "$r" ] || continue
  b=$(basename "$r")
  if ! grep -qs -- "raw/$b" "$KB"/pages/*.md; then
    addW "raw/$b 没有任何一页 source 指向它（可能是暂存，也可能是那次入库没做完）"
  fi
done

# ---------- 出报告 ----------
SELF_SUM=$(md5sum "$0" 2>/dev/null | cut -c1-8)
SELF_N=$(grep -c "" "$0" 2>/dev/null | tr -d ' ')
echo "──────── 知识库体检 v3.27（${TOTAL} 项） md5=${SELF_SUM:-?} 行数=${SELF_N:-?} ────────"
echo "库根：$(cd "$KB" && pwd)"
echo "页数：$(ls "$KB/pages/" 2>/dev/null | grep -c '\.md$')　索引活行合计：$LIVE_ALL（主索引 $LIVE + $SHARD_N 个分片）"
echo
if [ "$DATEOK" = "0" ]; then SKIP=2; SKIPNOTE="date 不支持 -d：draft 超 30 天、stable 超 180 天 两项未执行"; fi
EXEC=$((TOTAL - SKIP - NA))
echo "执行 $EXEC 项 / 跳过 $SKIP 项 / 不适用 $NA 项"
[ "$NA" -gt 0 ] && echo "不适用：$NANOTE（对象不存在，不算没查）"
echo "错按检查项计，不按根因计（一个根因可能被两项同时报出来）"
[ "$SKIP" -gt 0 ] && echo "⚠️ 有跳过：$SKIPNOTE —— **本次不算通过**"
if [ ${#E[@]} -eq 0 ]; then echo "错：0"; else
  echo "错：${#E[@]}"
  for x in "${E[@]}"; do echo "  - $x"; done
fi
if [ ${#W[@]} -eq 0 ]; then echo "提示：0"; else
  echo "提示：${#W[@]}（只提醒，不必动手）"
  for x in "${W[@]}"; do echo "  - $x"; done
fi
if [ "$SKIP" -gt 0 ]; then
  [ ${#E[@]} -gt 0 ] && echo "⚠️ 退出码 2 不等于没有错：上面那 ${#E[@]} 条错要先看，别只读码就放过"
  exit 2
fi
[ ${#E[@]} -gt 0 ] && exit 1
exit 0
