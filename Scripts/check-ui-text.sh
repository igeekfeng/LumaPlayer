#!/bin/bash
#
# check-ui-text.sh
#
# 界面文案守卫:**界面不写说明书**。
#
# 规则(见 CLAUDE.md「界面文案」):
#   1. 页头 / 表单头 / 弹窗卡片的 `subtitle:` / `hint:` 只放错误、阻塞原因或数据标签,
#      不放「这一页是干什么的」这类讲解句子;
#   2. `Section` 不挂 `footer:` 讲解段落 —— 取舍与副作用挂到 `InfoHint`(ⓘ 悬停提示);
#   3. 空态的 `description:` 不放引导话术,靠图标 + 标题 + 一个动作按钮说明。
#
# 判定方式:找出上面三类位置里的中文字面量,中文字符数超过 MAX_CJK 即命中。
# **不是**精确排版规则,只是「有没有又把段落塞回界面」的探针。
#
# 用法(仓库根执行):
#   ./Scripts/check-ui-text.sh
# 退出码 0 = 干净;1 = 有命中,逐条列出。
#
# 需要放宽时:把那句话挪进 `InfoHint(text:)` / `.help(...)` / `accessibilityLabel(...)`,
# ⛔ 不要调大 MAX_CJK 让它过。

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# 单条界面文案的中文字数上限。一句话说不清 = 该藏进悬停提示。
MAX_CJK=24
export MAX_CJK
export UI_TEXT_ROOT='LumaPlayer'

[ -d "$UI_TEXT_ROOT" ] || { echo "找不到源码目录 $UI_TEXT_ROOT"; exit 1; }

LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 perl -CS -e '
use strict;
use warnings;
use utf8;
use File::Find;

my $max  = $ENV{MAX_CJK};
my $root = $ENV{UI_TEXT_ROOT};

my @files;
find(sub { push @files, $File::Find::name if /\.swift$/ }, $root);
@files = sort @files;

my $fail = 0;
my %buckets = (
    subtitle    => { label => "页头 / 表单头 / 卡片副标题里有讲解句子(删掉或改成 InfoHint)", hits => [] },
    hint        => { label => "弹窗卡片副标题里有讲解句子(删掉或改成 InfoHint)",           hits => [] },
    description => { label => "空态 description 里有引导话术(删掉,只留标题 + 图标 + 一个按钮)", hits => [] },
    footer      => { label => "Section footer 里有讲解段落(挪进 InfoHint)",              hits => [] },
);

sub han {
    my ($s) = @_;
    return () = $s =~ /\p{Han}/g;
}

# 把可能跨行 / 用 + 拼接的字符串字面量收成一个字符串
sub join_literals {
    my ($raw) = @_;
    my @parts = $raw =~ /"((?:[^"\\]|\\.)*)"/g;
    return join("", @parts);
}

for my $file (@files) {
    open my $fh, "<:encoding(UTF-8)", $file or next;
    my @lines = <$fh>;
    close $fh;

    my $text  = join("", @lines);
    my $state = undef;   # 当前是否在某个 footer: { ... } 块里
    my $depth = 0;

    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        my $ln   = $i + 1;
        next if $line =~ m{^\s*//};

        # ── 1/2. subtitle: / hint: ──
        for my $key (qw(subtitle hint)) {
            next unless $line =~ /\b$key\s*:\s*(.*)$/;
            my $rest = $1;
            # 跨行拼接:下一行以 + 开头就继续吃
            my $j = $i;
            my $lit = $rest;
            while ($lit !~ /\A\s*(?:"(?:[^"\\]|\\.)*"\s*\+?\s*)+\z/ && $j + 1 <= $#lines
                   && $lines[$j + 1] =~ /^\s*\+/) {
                $j++;
                $lit .= " " . $lines[$j];
            }
            my $s  = join_literals($lit);
            my $n  = han($s);
            push @{ $buckets{$key}{hits} }, [ $file, $ln, $n, $s ] if $n > $max;
        }

        # ── 3. description: Text("...") 与 description: { ──
        if ($line =~ /\bdescription\s*:\s*Text\(\s*(.*)$/) {
            my $s = join_literals($1);
            my $n = han($s);
            push @{ $buckets{description}{hits} }, [ $file, $ln, $n, $s ] if $n > $max;
        }

        # ── 4. footer: { ... } 里裸 Text("...") ──
        if (defined $state) {
            if ($line =~ /\bText\(\s*(.*)$/) {
                my $s = join_literals($1);
                my $n = han($s);
                push @{ $buckets{footer}{hits} }, [ $file, $ln, $n, $s ] if $n > $max;
            }
            $depth += () = $line =~ /\{/g;
            $depth -= () = $line =~ /\}/g;
            $state = undef if $depth <= 0;
        } elsif ($line =~ /\bfooter\s*:\s*\{\s*$/) {
            $state = 1;
            $depth = 1;
        }
    }
}

for my $key (qw(subtitle hint description footer)) {
    my $hits = $buckets{$key}{hits};
    next unless @$hits;
    $fail = 1;
    print "\n❌ $buckets{$key}{label}\n";
    for my $h (@$hits) {
        my ($file, $ln, $n, $s) = @$h;
        $s =~ s/\s+/ /g;
        printf "  %s:%d  (%d 字)  %s\n", $file, $ln, $n, substr($s, 0, 70);
    }
}

if ($fail) {
    print <<"EOT";

把上面这些句子挪走,而不是缩短一两个字:
  • 设置项为什么这样取舍 → InfoHint(text:) 挂到 Section header 的 ⓘ
  • 控件的细节与副作用   → .help(...)(悬停提示)
  • 空态怎么恢复         → 一个动作按钮(刷新 / 添加 / 显示全部),不要一段话
EOT
    exit 1;
}

print "✅ 界面文案干净:没有超过 $max 字的副标题 / footer / 空态说明。\n";
exit 0;
'
