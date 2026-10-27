# عقد البيانات

المرجع: `SRC-xxxx / filename / chapter=null / title=null / Lstart–Lend`. العنوان والرقم الحقيقي لا يملآن بالتخمين. الثقة تقيس قوة الإسناد، لا صحة اعتقاد الشخصية داخل العالم.

`chapters`: سجل لكل ملف، بصمات، طول، أعلام جودة، وحالة القراءة. `candidates`: مطابقة آلية محدودة الحصيلة والقاموس، وقد تخلط أسماء الغو بالأشخاص وتفوت الأسماء البديلة. لا توجد دعوى شمول استخراج الكيانات. `facts`: حقيقة سردية أو ذاكرة شخصية أو تفسير مع الإحالة. `events`: ancient / previous-life / main منفصلة. `knowledge`: known / belief / inference / false_information / concealed / reader_only مع حدود المرحلة. `relationships`: علاقات موجهة زمنية. `decisions`: بدائل ومخاطر ومعلومات وقت الفعل. `causal_edges`: direct_cause / necessary_condition / contributing_factor / possible_outcome / temporal_only / uncertain.

علاقة `temporal_only` مستبعدة من اجتياز الاعتماد. العلاقة المساعدة لا تعني أن حذفها يمنع النتيجة حتمًا. لا تعني معرفة القارئ معرفة الشخصية؛ `valid_until=null` تعني أن نهاية الحالة لم تُثبت بعد، لا استمرارها إلى نهاية الرواية.

أمثلة:

```
python research/reverend-insanity/tools/query.py source 2 --start 117 --end 155
python research/reverend-insanity/tools/query.py search 'فانغ تشينغ'
python research/reverend-insanity/tools/query.py dependents EV-MAIN-0001
python research/reverend-insanity/tools/query.py status
```

إعادة الفهرسة تجدد جداول المصدر والمرشحات فقط. بعد تشغيلها تُعاد علامات المراجعة من `19-research-progress/checkpoint.json` بأداة التحقق؛ لا تُستنتج القراءة من مجرد تشغيل السكربت.
