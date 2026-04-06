
# Figma Image to Canvas


figma image object:

```json
{
    "absoluteBoundingBox" : {
    "height" : 121.71765899658203,
    "width" : 121.71765899658203,
    "x" : 103,
    "y" : 356
    },
    "absoluteRenderBounds" : {
    "height" : 121.7176513671875,
    "width" : 121.7176513671875,
    "x" : 103,
    "y" : 356
    },
    "blendMode" : "PASS_THROUGH",
    "constraints" : {
    "horizontal" : "MIN",
    "vertical" : "MIN"
    },
    "cornerRadius" : 0,
    "cornerSmoothing" : 0,
    "effects" : [

    ],
    "exportSettings" : [

    ],
    "fills" : [
    {
        "blendMode" : "NORMAL",
        "filters" : {
        "contrast" : 0,
        "exposure" : 0,
        "highlights" : 0,
        "saturation" : 0,
        "shadows" : 0,
        "temperature" : 0,
        "tint" : 0
        },
        "imageHash" : "72963454773dc84b7bd498d055424636a99d576c",
        "imageTransform" : [
        [
            1,
            0,
            0
        ],
        [
            0,
            1,
            0
        ]
        ],
        "opacity" : 1,
        "rotation" : 0,
        "scaleMode" : "FILL",
        "scalingFactor" : 0.5,
        "type" : "IMAGE",
        "visible" : true
    }
    ],
    "id" : "102:13",
    "isMask" : false,
    "layoutAlign" : "INHERIT",
    "layoutGrow" : 0,
    "layoutPositioning" : "AUTO",
    "layoutSizingHorizontal" : "FIXED",
    "layoutSizingVertical" : "FIXED",
    "locked" : false,
    "maskType" : "ALPHA",
    "maxHeight" : null,
    "maxWidth" : null,
    "minHeight" : null,
    "minWidth" : null,
    "name" : "alien-svgrepo-com-2 1",
    "opacity" : 1,
    "relativeTransform" : [
    [
        1,
        0,
        163
    ],
    [
        0,
        1,
        362
    ]
    ],
    "rotation" : 0,
    "strokeAlign" : "INSIDE",
    "strokeCap" : "NONE",
    "strokeJoin" : "MITER",
    "strokes" : [

    ],
    "strokeWeight" : 1,
    "type" : "RECTANGLE",
    "visible" : true
}
```


To draw an image on the canvas, you can use the `Image` class from `kivy.core.image` to load the image and get its texture. Then, you can use the `Rectangle` instruction to draw the texture on the canvas.

Here's an example of how to do this in Python:



```py
from kivy.core.image import Image as CoreImage

texture = CoreImage('logo.png').texture

img_rect = Rectangle(texture=texture, pos=self.pos, size=self.size)

```

or simpler by 

```py
from kivy.core.image import Image as CoreImage

img_rect = Rectangle(source='mylogo.png', pos=self.pos, size=self.size)
```
for now implement the "simpler"

https://github.com/kivy/kivy/blob/master/kivy/core/image/__init__.py

