# Prevent onnxruntime from being bundled — not needed by RimeoAgent
# (pulled in transitively by transformers but unused)
excludedimports = ['onnxruntime']
