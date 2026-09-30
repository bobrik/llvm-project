; RUN: opt -S -verify-each -verify-memoryssa -passes='function(memcpyopt,dse)' %s | FileCheck %s
;
; CHECK-LABEL: define i64 @vector_source_mod_backedge(
; CHECK: call void @llvm.memcpy.p0.p0.i64(

; The source changes after the first inner-loop read. All later reads must
; still see this iteration's copied snapshot.
declare void @free(ptr allocptr captures(address)) nounwind allockind("free")
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg)
declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))

define i64 @vector_source_mod_backedge(ptr noalias align 8 %src, i64 %count) {
; MEMCPYOPT-LABEL: define i64 @vector_source_mod_backedge(
; MEMCPYOPT-SAME: ptr noalias align 8 [[SRC:%.*]], i64 [[COUNT:%.*]]) {
; MEMCPYOPT-NEXT:  [[ENTRY:.*]]:
; MEMCPYOPT-NEXT:    [[EMPTY:%.*]] = icmp eq i64 [[COUNT]], 0
; MEMCPYOPT-NEXT:    br i1 [[EMPTY]], label %[[FINISH:.*]], label %[[OUTER:.*]]
; MEMCPYOPT:       [[OUTER]]:
; MEMCPYOPT-NEXT:    [[ELEMENT:%.*]] = phi ptr [ [[SRC]], %[[ENTRY]] ], [ [[FOLLOWING:%.*]], %[[EXIT:.*]] ]
; MEMCPYOPT-NEXT:    [[INDEX:%.*]] = phi i64 [ 0, %[[ENTRY]] ], [ [[INDEX_NEXT:%.*]], %[[EXIT]] ]
; MEMCPYOPT-NEXT:    [[TOTAL:%.*]] = phi i64 [ 0, %[[ENTRY]] ], [ [[ADDED:%.*]], %[[EXIT]] ]
; MEMCPYOPT-NEXT:    br label %[[LOOP:.*]]
; MEMCPYOPT:       [[LOOP]]:
; MEMCPYOPT-NEXT:    [[I:%.*]] = phi i64 [ 0, %[[OUTER]] ], [ [[NEXT:%.*]], %[[LOOP]] ]
; MEMCPYOPT-NEXT:    [[SUM:%.*]] = phi i64 [ [[TOTAL]], %[[OUTER]] ], [ [[ADDED]], %[[LOOP]] ]
; MEMCPYOPT-NEXT:    [[P:%.*]] = getelementptr i64, ptr [[ELEMENT]], i64 [[I]]
; MEMCPYOPT-NEXT:    [[VALUE:%.*]] = load i64, ptr [[P]], align 8
; MEMCPYOPT-NEXT:    [[ADDED]] = add i64 [[SUM]], [[VALUE]]
; MEMCPYOPT-NEXT:    [[NEXT]] = add nuw i64 [[I]], 1
; MEMCPYOPT-NEXT:    [[DONE:%.*]] = icmp eq i64 [[NEXT]], 512
; MEMCPYOPT-NEXT:    br i1 [[DONE]], label %[[EXIT]], label %[[LOOP]]
; MEMCPYOPT:       [[EXIT]]:
; MEMCPYOPT-NEXT:    [[FOLLOWING]] = getelementptr inbounds i8, ptr [[ELEMENT]], i64 4096
; MEMCPYOPT-NEXT:    [[INDEX_NEXT]] = add nuw i64 [[INDEX]], 1
; MEMCPYOPT-NEXT:    [[FINISHED:%.*]] = icmp eq i64 [[INDEX_NEXT]], [[COUNT]]
; MEMCPYOPT-NEXT:    br i1 [[FINISHED]], label %[[FINISH]], label %[[OUTER]]
; MEMCPYOPT:       [[FINISH]]:
; MEMCPYOPT-NEXT:    [[RESULT:%.*]] = phi i64 [ 0, %[[ENTRY]] ], [ [[ADDED]], %[[EXIT]] ]
; MEMCPYOPT-NEXT:    call void @free(ptr [[SRC]])
; MEMCPYOPT-NEXT:    ret i64 [[RESULT]]
;
; O3-LABEL: define i64 @vector_source_mod_backedge(
; O3-SAME: ptr noalias align 8 captures(address) [[SRC:%.*]], i64 [[COUNT:%.*]]) local_unnamed_addr #[[ATTR1:[0-9]+]] {
; O3-NEXT:  [[ENTRY:.*]]:
; O3-NEXT:    [[EMPTY:%.*]] = icmp eq i64 [[COUNT]], 0
; O3-NEXT:    br i1 [[EMPTY]], label %[[FINISH:.*]], label %[[OUTER:.*]]
; O3:       [[OUTER]]:
; O3-NEXT:    [[ELEMENT:%.*]] = phi ptr [ [[FOLLOWING:%.*]], %[[EXIT:.*]] ], [ [[SRC]], %[[ENTRY]] ]
; O3-NEXT:    [[INDEX:%.*]] = phi i64 [ [[INDEX_NEXT:%.*]], %[[EXIT]] ], [ 0, %[[ENTRY]] ]
; O3-NEXT:    [[TOTAL:%.*]] = phi i64 [ [[ADDED:%.*]], %[[EXIT]] ], [ 0, %[[ENTRY]] ]
; O3-NEXT:    br label %[[LOOP:.*]]
; O3:       [[LOOP]]:
; O3-NEXT:    [[I:%.*]] = phi i64 [ 0, %[[OUTER]] ], [ [[NEXT:%.*]], %[[LOOP]] ]
; O3-NEXT:    [[SUM:%.*]] = phi i64 [ [[TOTAL]], %[[OUTER]] ], [ [[ADDED]], %[[LOOP]] ]
; O3-NEXT:    [[P:%.*]] = getelementptr [8 x i8], ptr [[ELEMENT]], i64 [[I]]
; O3-NEXT:    [[VALUE:%.*]] = load i64, ptr [[P]], align 8
; O3-NEXT:    [[ADDED]] = add i64 [[VALUE]], [[SUM]]
; O3-NEXT:    [[NEXT]] = add nuw nsw i64 [[I]], 1
; O3-NEXT:    [[DONE:%.*]] = icmp eq i64 [[NEXT]], 512
; O3-NEXT:    br i1 [[DONE]], label %[[EXIT]], label %[[LOOP]]
; O3:       [[EXIT]]:
; O3-NEXT:    [[FOLLOWING]] = getelementptr inbounds nuw i8, ptr [[ELEMENT]], i64 4096
; O3-NEXT:    [[INDEX_NEXT]] = add nuw i64 [[INDEX]], 1
; O3-NEXT:    [[FINISHED:%.*]] = icmp eq i64 [[INDEX_NEXT]], [[COUNT]]
; O3-NEXT:    br i1 [[FINISHED]], label %[[FINISH]], label %[[OUTER]]
; O3:       [[FINISH]]:
; O3-NEXT:    [[RESULT:%.*]] = phi i64 [ 0, %[[ENTRY]] ], [ [[ADDED]], %[[EXIT]] ]
; O3-NEXT:    tail call void @free(ptr [[SRC]])
; O3-NEXT:    ret i64 [[RESULT]]
;
entry:
  %tmp = alloca [4104 x i8], align 8
  %payload = getelementptr inbounds i8, ptr %tmp, i64 8
  %empty = icmp eq i64 %count, 0
  br i1 %empty, label %finish, label %outer

outer:
  %element = phi ptr [ %src, %entry ], [ %following, %exit ]
  %index = phi i64 [ 0, %entry ], [ %index.next, %exit ]
  %total = phi i64 [ 0, %entry ], [ %added, %exit ]
  call void @llvm.lifetime.start.p0(ptr %tmp)
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %payload, ptr align 8 %element, i64 4096, i1 false)
  br label %loop

loop:
  %i = phi i64 [ 0, %outer ], [ %next, %loop ]
  %sum = phi i64 [ %total, %outer ], [ %added, %loop ]
  %p = getelementptr inbounds nuw i64, ptr %payload, i64 %i
  %value = load i64, ptr %p, align 8
  %added = add i64 %sum, %value
  %second = getelementptr inbounds i64, ptr %element, i64 1
  store i64 99, ptr %second, align 8
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 512
  br i1 %done, label %exit, label %loop

exit:
  call void @llvm.lifetime.end.p0(ptr %tmp)
  %following = getelementptr inbounds i8, ptr %element, i64 4096
  %index.next = add nuw i64 %index, 1
  %finished = icmp eq i64 %index.next, %count
  br i1 %finished, label %finish, label %outer

finish:
  %result = phi i64 [ 0, %entry ], [ %added, %exit ]
  call void @free(ptr %src)
  ret i64 %result
}

