/*
Copyright 2019 The Tekton Authors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package taskrun

import (
	"errors"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/google/go-cmp/cmp"
	v1 "github.com/tektoncd/pipeline/pkg/apis/pipeline/v1"
	"github.com/tektoncd/pipeline/pkg/reconciler/taskrun/resources"
	"github.com/tektoncd/pipeline/test/diff"
)

func TestValidateResolvedTask_ValidParams(t *testing.T) {
	ctx := t.Context()
	task := &v1.Task{
		ObjectMeta: metav1.ObjectMeta{Name: "foo"},
		Spec: v1.TaskSpec{
			Steps: []v1.Step{{
				Image:   "myimage",
				Command: []string{"mycmd"},
			}},
			Params: []v1.ParamSpec{
				{
					Name: "foo",
					Type: v1.ParamTypeString,
				}, {
					Name: "bar",
					Type: v1.ParamTypeString,
				}, {
					Name: "zoo",
					Type: v1.ParamTypeString,
				}, {
					Name: "matrixParam",
					Type: v1.ParamTypeString,
				}, {
					Name: "include",
					Type: v1.ParamTypeString,
				}, {
					Name: "arrayResultRef",
					Type: v1.ParamTypeArray,
				}, {
					Name: "myObjWithoutDefault",
					Type: v1.ParamTypeObject,
					Properties: map[string]v1.PropertySpec{
						"key1": {},
						"key2": {},
					},
				}, {
					Name: "myObjWithDefault",
					Type: v1.ParamTypeObject,
					Properties: map[string]v1.PropertySpec{
						"key1": {},
						"key2": {},
						"key3": {},
					},
					Default: &v1.ParamValue{
						Type: v1.ParamTypeObject,
						ObjectVal: map[string]string{
							"key1": "val1-default",
							"key2": "val2-default", // key2 is also provided and will be overridden by taskrun
							// key3 will be provided by taskrun
						},
					},
				},
			},
		},
	}
	rtr := &resources.ResolvedTask{
		TaskSpec: &task.Spec,
	}
	p := v1.Params{{
		Name:  "foo",
		Value: *v1.NewStructuredValues("somethinggood"),
	}, {
		Name:  "bar",
		Value: *v1.NewStructuredValues("somethinggood"),
	}, {
		Name:  "arrayResultRef",
		Value: *v1.NewStructuredValues("$(results.resultname[*])"),
	}, {
		Name: "myObjWithoutDefault",
		Value: *v1.NewObject(map[string]string{
			"key1":      "val1",
			"key2":      "val2",
			"extra_key": "val3",
		}),
	}, {
		Name: "myObjWithDefault",
		Value: *v1.NewObject(map[string]string{
			"key2": "val2",
			"key3": "val3",
		}),
	}}
	m := &v1.Matrix{
		Params: v1.Params{{
			Name:  "zoo",
			Value: *v1.NewStructuredValues("a", "b", "c"),
		}, {
			Name: "matrixParam", Value: v1.ParamValue{Type: v1.ParamTypeArray, ArrayVal: []string{}},
		}},
		Include: []v1.IncludeParams{{
			Name: "build-1",
			Params: v1.Params{{
				Name: "include", Value: v1.ParamValue{Type: v1.ParamTypeString, StringVal: "string-1"},
			}},
		}},
	}
	if err := ValidateResolvedTask(ctx, p, m, rtr); err != nil {
		t.Errorf("Did not expect to see error when validating TaskRun with correct params but saw %v", err)
	}
}

func TestValidateResolvedTask_ExtraValidParams(t *testing.T) {
	ctx := t.Context()
	tcs := []struct {
		name   string
		task   v1.Task
		params v1.Params
		matrix *v1.Matrix
	}{{
		name: "extra-str-param",
		task: v1.Task{
			ObjectMeta: metav1.ObjectMeta{Name: "foo"},
			Spec: v1.TaskSpec{
				Params: []v1.ParamSpec{{
					Name: "foo",
					Type: v1.ParamTypeString,
				}},
			},
		},
		params: v1.Params{{
			Name:  "foo",
			Value: *v1.NewStructuredValues("string"),
		}, {
			Name:  "extrastr",
			Value: *v1.NewStructuredValues("extra"),
		}},
	}, {
		name: "extra-arr-param",
		task: v1.Task{
			ObjectMeta: metav1.ObjectMeta{Name: "foo"},
			Spec: v1.TaskSpec{
				Params: []v1.ParamSpec{{
					Name: "foo",
					Type: v1.ParamTypeString,
				}},
			},
		},
		params: v1.Params{{
			Name:  "foo",
			Value: *v1.NewStructuredValues("string"),
		}, {
			Name:  "extraArr",
			Value: *v1.NewStructuredValues("extra", "arr"),
		}},
	}, {
		name: "extra-obj-param",
		task: v1.Task{
			ObjectMeta: metav1.ObjectMeta{Name: "foo"},
			Spec: v1.TaskSpec{
				Params: []v1.ParamSpec{{
					Name: "foo",
					Type: v1.ParamTypeString,
				}},
			},
		},
		params: v1.Params{{
			Name:  "foo",
			Value: *v1.NewStructuredValues("string"),
		}, {
			Name: "myObjWithDefault",
			Value: *v1.NewObject(map[string]string{
				"key2": "val2",
				"key3": "val3",
			}),
		}},
	}, {
		name: "extra-param-matrix",
		task: v1.Task{
			ObjectMeta: metav1.ObjectMeta{Name: "foo"},
			Spec: v1.TaskSpec{
				Params: []v1.ParamSpec{{
					Name: "include",
					Type: v1.ParamTypeString,
				}},
			},
		},
		params: v1.Params{{}},
		matrix: &v1.Matrix{
			Params: v1.Params{{
				Name:  "extraArr",
				Value: *v1.NewStructuredValues("extra", "arr"),
			}},
			Include: []v1.IncludeParams{{
				Name: "build-1",
				Params: v1.Params{{
					Name: "include", Value: *v1.NewStructuredValues("string"),
				}},
			}},
		},
	}}
	for _, tc := range tcs {
		rtr := &resources.ResolvedTask{
			TaskSpec: &tc.task.Spec,
		}
		t.Run(tc.name, func(t *testing.T) {
			if err := ValidateResolvedTask(ctx, tc.params, tc.matrix, rtr); err != nil {
				t.Errorf("Did not expect to see error when validating TaskRun with correct params but saw %v", err)
			}
		})
	}
}

func TestValidateResolvedTask_InvalidParams(t *testing.T) {
	ctx := t.Context()
	tcs := []struct {
		name    string
		task    v1.Task
		params  v1.Params
		matrix  *v1.Matrix
		wantErr string
	}{{
		name: "missing-params-string",
		task: v1.Task{
			ObjectMeta: metav1.ObjectMeta{Name: "foo"},
			Spec: v1.TaskSpec{
				Params: []v1.ParamSpec{{
					Name: "foo",
					Type: v1.ParamTypeString,
				}},
			},
		},
		params: v1.Params{{
			Name:  "missing",
			Value: *v1.NewStructuredValues("somethingfun"),
		}},
		matrix:  &v1.Matrix{},
		wantErr: "invalid input params for task : missing values for these params which have no default values: [foo]",
	}, {
		name: "missing-params-arr",
		task: v1.Task{
			ObjectMeta: metav1.ObjectMeta{Name: "foo"},
			Spec: v1.TaskSpec{
				Params: []v1.ParamSpec{{
					Name: "foo",
					Type: v1.ParamTypeArray,
				}},
			},
		},
		params: v1.Params{{
			Name:  "missing",
			Value: *v1.NewStructuredValues("array", "param"),
		}},
		matrix:  &v1.Matrix{},
		wantErr: "invalid input params for task : missing values for these params which have no default values: [foo]",
	}, {
		name: "invalid-string-param",
		task: v1.Task{
			ObjectMeta: metav1.ObjectMeta{Name: "foo"},
			Spec: v1.TaskSpec{
				Params: []v1.ParamSpec{{
					Name: "foo",
					Type: v1.ParamTypeString,
				}},
			},
		},
		params: v1.Params{{
			Name:  "foo",
			Value: *v1.NewStructuredValues("array", "param"),
		}},
		matrix:  &v1.Matrix{},
		wantErr: "invalid input params for task : param types don't match the user-specified type: [foo]",
	}, {
		name: "invalid-arr-param",
		task: v1.Task{
			ObjectMeta: metav1.ObjectMeta{Name: "foo"},
			Spec: v1.TaskSpec{
				Params: []v1.ParamSpec{{
					Name: "foo",
					Type: v1.ParamTypeArray,
				}},
			},
		},
		params: v1.Params{{
			Name:  "foo",
			Value: *v1.NewStructuredValues("string"),
		}},
		matrix:  &v1.Matrix{},
		wantErr: "invalid input params for task : param types don't match the user-specified type: [foo]",
	}, {
		name: "missing-param-in-matrix",
		task: v1.Task{
			ObjectMeta: metav1.ObjectMeta{Name: "foo"},
			Spec: v1.TaskSpec{
				Params: []v1.ParamSpec{{
					Name: "bar",
					Type: v1.ParamTypeArray,
				}},
			},
		},
		params: v1.Params{{}},
		matrix: &v1.Matrix{
			Params: v1.Params{{
				Name:  "missing",
				Value: *v1.NewStructuredValues("foo"),
			}},
		},
		wantErr: "invalid input params for task : missing values for these params which have no default values: [bar]",
	}, {
		name: "missing-param-in-matrix-include",
		task: v1.Task{
			ObjectMeta: metav1.ObjectMeta{Name: "foo"},
			Spec: v1.TaskSpec{
				Params: []v1.ParamSpec{{
					Name: "bar",
					Type: v1.ParamTypeArray,
				}},
			},
		},
		params: v1.Params{{}},
		matrix: &v1.Matrix{
			Include: []v1.IncludeParams{{
				Name: "build-1",
				Params: v1.Params{{
					Name: "missing", Value: v1.ParamValue{Type: v1.ParamTypeString, StringVal: "string"},
				}},
			}},
		},
		wantErr: "invalid input params for task : missing values for these params which have no default values: [bar]",
	}, {
		name: "invalid-arr-in-matrix-param",
		task: v1.Task{
			ObjectMeta: metav1.ObjectMeta{Name: "foo"},
			Spec: v1.TaskSpec{
				Params: []v1.ParamSpec{{
					Name: "bar",
					Type: v1.ParamTypeArray,
				}},
			},
		},
		params: v1.Params{{}},
		matrix: &v1.Matrix{
			Params: v1.Params{{
				Name:  "bar",
				Value: *v1.NewStructuredValues("foo"),
			}},
		},
		wantErr: "invalid input params for task : param types don't match the user-specified type: [bar]",
	}, {
		name: "invalid-str-in-matrix-include-param",
		task: v1.Task{
			ObjectMeta: metav1.ObjectMeta{Name: "foo"},
			Spec: v1.TaskSpec{
				Params: []v1.ParamSpec{{
					Name: "bar",
					Type: v1.ParamTypeArray,
				}},
			},
		},
		params: v1.Params{{}},
		matrix: &v1.Matrix{
			Include: []v1.IncludeParams{{
				Name: "build-1",
				Params: v1.Params{{
					Name: "bar", Value: v1.ParamValue{Type: v1.ParamTypeString, StringVal: "string"},
				}},
			}},
		},
		wantErr: "invalid input params for task : param types don't match the user-specified type: [bar]",
	}, {
		name: "missing-params-obj",
		task: v1.Task{
			ObjectMeta: metav1.ObjectMeta{Name: "foo"},
			Spec: v1.TaskSpec{
				Params: []v1.ParamSpec{{
					Name: "foo",
					Type: v1.ParamTypeArray,
				}},
			},
		},
		params: v1.Params{{
			Name: "missing-obj",
			Value: *v1.NewObject(map[string]string{
				"key1":    "val1",
				"misskey": "val2",
			}),
		}},
		matrix:  &v1.Matrix{},
		wantErr: "invalid input params for task : missing values for these params which have no default values: [foo]",
	}, {
		name: "missing object param keys",
		task: v1.Task{
			ObjectMeta: metav1.ObjectMeta{Name: "foo"},
			Spec: v1.TaskSpec{
				Params: []v1.ParamSpec{{
					Name: "myObjWithoutDefault",
					Type: v1.ParamTypeObject,
					Properties: map[string]v1.PropertySpec{
						"key1": {},
						"key2": {},
					},
				}},
			},
		},
		params: v1.Params{{
			Name: "myObjWithoutDefault",
			Value: *v1.NewObject(map[string]string{
				"key1":    "val1",
				"misskey": "val2",
			}),
		}},
		matrix:  &v1.Matrix{},
		wantErr: "invalid input params for task : missing keys for these params which are required in ParamSpec's properties map[myObjWithoutDefault:[key2]]",
	}}
	for _, tc := range tcs {
		rtr := &resources.ResolvedTask{
			TaskSpec: &tc.task.Spec,
		}
		t.Run(tc.name, func(t *testing.T) {
			err := ValidateResolvedTask(ctx, tc.params, tc.matrix, rtr)
			if d := cmp.Diff(tc.wantErr, err.Error()); d != "" {
				t.Errorf("Did not get the expected Error  %s", diff.PrintWantGot(d))
			}
		})
	}
}

func TestValidateOverrides(t *testing.T) {
	tcs := []struct {
		name    string
		ts      *v1.TaskSpec
		trs     *v1.TaskRunSpec
		wantErr bool
	}{{
		name: "valid stepOverrides",
		ts: &v1.TaskSpec{
			Steps: []v1.Step{{
				Name: "step1",
			}, {
				Name: "step2",
			}},
		},
		trs: &v1.TaskRunSpec{
			StepSpecs: []v1.TaskRunStepSpec{{
				Name: "step1",
			}},
		},
	}, {
		name: "valid sidecarOverrides",
		ts: &v1.TaskSpec{
			Sidecars: []v1.Sidecar{{
				Name: "step1",
			}, {
				Name: "step2",
			}},
		},
		trs: &v1.TaskRunSpec{
			SidecarSpecs: []v1.TaskRunSidecarSpec{{
				Name: "step1",
			}},
		},
	}, {
		name: "invalid stepOverrides",
		ts:   &v1.TaskSpec{},
		trs: &v1.TaskRunSpec{
			StepSpecs: []v1.TaskRunStepSpec{{
				Name: "step1",
			}},
		},
		wantErr: true,
	}, {
		name: "invalid sidecarOverrides",
		ts:   &v1.TaskSpec{},
		trs: &v1.TaskRunSpec{
			SidecarSpecs: []v1.TaskRunSidecarSpec{{
				Name: "step1",
			}},
		},
		wantErr: true,
	}}
	for _, tc := range tcs {
		t.Run(tc.name, func(t *testing.T) {
			err := validateOverrides(tc.ts, tc.trs)
			if (err != nil) != tc.wantErr {
				t.Errorf("expected err: %t, but got err %s", tc.wantErr, err)
			}
		})
	}
}

func TestValidateResult(t *testing.T) {
	tcs := []struct {
		name    string
		tr      *v1.TaskRun
		rtr     *v1.TaskSpec
		wantErr bool
	}{{
		name: "valid taskrun spec results",
		tr: &v1.TaskRun{
			Spec: v1.TaskRunSpec{
				TaskSpec: &v1.TaskSpec{
					Results: []v1.TaskResult{
						{
							Name: "string-result",
							Type: v1.ResultsTypeString,
						},
						{
							Name: "array-result",
							Type: v1.ResultsTypeArray,
						},
						{
							Name:       "object-result",
							Type:       v1.ResultsTypeObject,
							Properties: map[string]v1.PropertySpec{"hello": {Type: "string"}},
						},
					},
				},
			},
			Status: v1.TaskRunStatus{
				TaskRunStatusFields: v1.TaskRunStatusFields{
					Results: []v1.TaskRunResult{
						{
							Name:  "string-result",
							Type:  v1.ResultsTypeString,
							Value: *v1.NewStructuredValues("hello"),
						},
						{
							Name:  "array-result",
							Type:  v1.ResultsTypeArray,
							Value: *v1.NewStructuredValues("hello", "world"),
						},
						{
							Name:  "object-result",
							Type:  v1.ResultsTypeObject,
							Value: *v1.NewObject(map[string]string{"hello": "world"}),
						},
					},
				},
			},
		},
		rtr: &v1.TaskSpec{
			Results: []v1.TaskResult{},
		},
		wantErr: false,
	}, {
		name: "valid taskspec results",
		tr: &v1.TaskRun{
			Spec: v1.TaskRunSpec{
				TaskSpec: &v1.TaskSpec{
					Results: []v1.TaskResult{
						{
							Name: "string-result",
							Type: v1.ResultsTypeString,
						},
						{
							Name: "array-result",
							Type: v1.ResultsTypeArray,
						},
						{
							Name: "object-result",
							Type: v1.ResultsTypeObject,
						},
					},
				},
			},
			Status: v1.TaskRunStatus{
				TaskRunStatusFields: v1.TaskRunStatusFields{
					Results: []v1.TaskRunResult{
						{
							Name:  "string-result",
							Type:  v1.ResultsTypeString,
							Value: *v1.NewStructuredValues("hello"),
						},
						{
							Name:  "array-result",
							Type:  v1.ResultsTypeArray,
							Value: *v1.NewStructuredValues("hello", "world"),
						},
						{
							Name:  "object-result",
							Type:  v1.ResultsTypeObject,
							Value: *v1.NewObject(map[string]string{"hello": "world"}),
						},
					},
				},
			},
		},
		rtr: &v1.TaskSpec{
			Results: []v1.TaskResult{},
		},
		wantErr: false,
	}, {
		name: "invalid taskrun spec results types",
		tr: &v1.TaskRun{
			Spec: v1.TaskRunSpec{
				TaskSpec: &v1.TaskSpec{
					Results: []v1.TaskResult{
						{
							Name: "string-result",
							Type: v1.ResultsTypeString,
						},
						{
							Name: "array-result",
							Type: v1.ResultsTypeArray,
						},
						{
							Name:       "object-result",
							Type:       v1.ResultsTypeObject,
							Properties: map[string]v1.PropertySpec{"hello": {Type: "string"}},
						},
					},
				},
			},
			Status: v1.TaskRunStatus{
				TaskRunStatusFields: v1.TaskRunStatusFields{
					Results: []v1.TaskRunResult{
						{
							Name:  "string-result",
							Type:  v1.ResultsTypeArray,
							Value: *v1.NewStructuredValues("hello", "world"),
						},
						{
							Name:  "array-result",
							Type:  v1.ResultsTypeObject,
							Value: *v1.NewObject(map[string]string{"hello": "world"}),
						},
						{
							Name:  "object-result",
							Type:  v1.ResultsTypeString,
							Value: *v1.NewStructuredValues("hello"),
						},
					},
				},
			},
		},
		rtr: &v1.TaskSpec{
			Results: []v1.TaskResult{},
		},
		wantErr: true,
	}, {
		name: "invalid taskspec results types",
		tr: &v1.TaskRun{
			Spec: v1.TaskRunSpec{
				TaskSpec: &v1.TaskSpec{
					Results: []v1.TaskResult{},
				},
			},
			Status: v1.TaskRunStatus{
				TaskRunStatusFields: v1.TaskRunStatusFields{
					Results: []v1.TaskRunResult{
						{
							Name:  "string-result",
							Type:  v1.ResultsTypeArray,
							Value: *v1.NewStructuredValues("hello", "world"),
						},
						{
							Name:  "array-result",
							Type:  v1.ResultsTypeObject,
							Value: *v1.NewObject(map[string]string{"hello": "world"}),
						},
						{
							Name:  "object-result",
							Type:  v1.ResultsTypeString,
							Value: *v1.NewStructuredValues("hello"),
						},
					},
				},
			},
		},
		rtr: &v1.TaskSpec{
			Results: []v1.TaskResult{
				{
					Name: "string-result",
					Type: v1.ResultsTypeString,
				},
				{
					Name: "array-result",
					Type: v1.ResultsTypeArray,
				},
				{
					Name:       "object-result",
					Type:       v1.ResultsTypeObject,
					Properties: map[string]v1.PropertySpec{"hello": {Type: "string"}},
				},
			},
		},
		wantErr: true,
	}, {
		name: "invalid taskrun spec results object properties",
		tr: &v1.TaskRun{
			Spec: v1.TaskRunSpec{
				TaskSpec: &v1.TaskSpec{
					Results: []v1.TaskResult{
						{
							Name:       "object-result",
							Type:       v1.ResultsTypeObject,
							Properties: map[string]v1.PropertySpec{"world": {Type: "string"}},
						},
					},
				},
			},
			Status: v1.TaskRunStatus{
				TaskRunStatusFields: v1.TaskRunStatusFields{
					Results: []v1.TaskRunResult{
						{
							Name:  "object-result",
							Type:  v1.ResultsTypeObject,
							Value: *v1.NewObject(map[string]string{"hello": "world"}),
						},
					},
				},
			},
		},
		rtr: &v1.TaskSpec{
			Results: []v1.TaskResult{},
		},
		wantErr: true,
	}, {
		name: "invalid taskspec results object properties",
		tr: &v1.TaskRun{
			Spec: v1.TaskRunSpec{
				TaskSpec: &v1.TaskSpec{
					Results: []v1.TaskResult{},
				},
			},
			Status: v1.TaskRunStatus{
				TaskRunStatusFields: v1.TaskRunStatusFields{
					Results: []v1.TaskRunResult{
						{
							Name:  "object-result",
							Type:  v1.ResultsTypeObject,
							Value: *v1.NewObject(map[string]string{"hello": "world"}),
						},
					},
				},
			},
		},
		rtr: &v1.TaskSpec{
			Results: []v1.TaskResult{
				{
					Name:       "object-result",
					Type:       v1.ResultsTypeObject,
					Properties: map[string]v1.PropertySpec{"world": {Type: "string"}},
				},
			},
		},
		wantErr: true,
	}, {
		name: "invalid taskrun spec results types with other valid types",
		tr: &v1.TaskRun{
			Spec: v1.TaskRunSpec{
				TaskSpec: &v1.TaskSpec{
					Results: []v1.TaskResult{
						{
							Name: "string-result",
							Type: v1.ResultsTypeString,
						},
						{
							Name: "array-result-1",
							Type: v1.ResultsTypeArray,
						},
						{
							Name: "array-result-2",
							Type: v1.ResultsTypeArray,
						},
						{
							Name:       "object-result",
							Type:       v1.ResultsTypeObject,
							Properties: map[string]v1.PropertySpec{"hello": {Type: "string"}},
						},
					},
				},
			},
			Status: v1.TaskRunStatus{
				TaskRunStatusFields: v1.TaskRunStatusFields{
					Results: []v1.TaskRunResult{
						{
							Name:  "string-result",
							Type:  v1.ResultsTypeString,
							Value: *v1.NewStructuredValues("hello"),
						},
						{
							Name:  "array-result-1",
							Type:  v1.ResultsTypeObject,
							Value: *v1.NewObject(map[string]string{"hello": "world"}),
						},
						{
							Name:  "array-result-2",
							Type:  v1.ResultsTypeString,
							Value: *v1.NewStructuredValues(""),
						},
						{
							Name:  "object-result",
							Type:  v1.ResultsTypeObject,
							Value: *v1.NewObject(map[string]string{"hello": "world"}),
						},
					},
				},
			},
		},
		rtr: &v1.TaskSpec{
			Results: []v1.TaskResult{},
		},
		wantErr: true,
	}}
	for _, tc := range tcs {
		t.Run(tc.name, func(t *testing.T) {
			err := validateTaskRunResults(tc.tr, tc.rtr)
			if err == nil && tc.wantErr {
				t.Errorf("expected err: %t, but got different err: %s", tc.wantErr, err)
			} else if err != nil && !tc.wantErr {
				t.Errorf("did not expect any err, but got err: %s", err)
			}
		})
	}
}

func TestEnumValidation_Success(t *testing.T) {
	tcs := []struct {
		name       string
		params     []v1.Param
		paramSpecs v1.ParamSpecs
	}{{
		name: "no enum list - success",
		params: []v1.Param{
			{
				Name: "p1",
				Value: v1.ParamValue{
					Type:      v1.ParamTypeString,
					StringVal: "v1",
				},
			},
		},
		paramSpecs: v1.ParamSpecs{
			{
				Name: "p1",
			},
		},
	}, {
		name: "optional param validation skipped - success",
		params: []v1.Param{
			{
				Name: "p1",
				Value: v1.ParamValue{
					Type: v1.ParamTypeString,
				},
			},
		},
		paramSpecs: v1.ParamSpecs{
			{
				Name:    "p1",
				Enum:    []string{"v1", "v2", "v3"},
				Default: &v1.ParamValue{Type: v1.ParamTypeString, StringVal: "v1"},
			},
		},
	}, {
		name: "non-string param validation skipped - success",
		params: []v1.Param{
			{
				Name: "p1",
				Value: v1.ParamValue{
					Type:     v1.ParamTypeArray,
					ArrayVal: []string{"a1", "a2"},
				},
			},
		},
		paramSpecs: v1.ParamSpecs{
			{
				Name: "p1",
				Type: v1.ParamTypeArray,
				Enum: []string{"v1", "v2", "v3"},
			},
		},
	}, {
		name: "value in the enum list - success",
		params: []v1.Param{
			{
				Name: "p1",
				Value: v1.ParamValue{
					StringVal: "v1",
				},
			},
			{
				Name: "p2",
				Value: v1.ParamValue{
					StringVal: "v2",
				},
			},
		},
		paramSpecs: v1.ParamSpecs{
			{
				Name: "p1",
				Enum: []string{"v1", "v2", "v3"},
			},
			{
				Name: "p2",
				Enum: []string{"v1", "v2", "v3"},
			},
		},
	}}

	for _, tc := range tcs {
		if err := ValidateEnumParam(t.Context(), tc.params, tc.paramSpecs); err != nil {
			t.Errorf("expected err is nil, but got %v", err)
		}
	}
}

func TestEnumValidation_Failure(t *testing.T) {
	tcs := []struct {
		name        string
		params      []v1.Param
		paramSpecs  v1.ParamSpecs
		expectedErr error
	}{{
		name: "value not in the enum list - failure",
		params: []v1.Param{
			{
				Name: "p1",
				Value: v1.ParamValue{
					StringVal: "v4",
					Type:      v1.ParamTypeString,
				},
			},
		},
		paramSpecs: v1.ParamSpecs{
			{
				Name: "p1",
				Enum: []string{"v1", "v2", "v3"},
			},
		},
		expectedErr: errors.New("param `p1` value: v4 is not in the enum list"),
	}}

	for _, tc := range tcs {
		if err := ValidateEnumParam(t.Context(), tc.params, tc.paramSpecs); err == nil {
			t.Errorf("expected error from ValidateEnumParam() = %v, but got none", tc.expectedErr)
		} else if d := cmp.Diff(tc.expectedErr.Error(), err.Error()); d != "" {
			t.Errorf("expected error does not match: %s", diff.PrintWantGot(d))
		}
	}
}
