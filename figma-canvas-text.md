
# Figma Text to Canvas


a normal Label Widget just draws text on the canvas, but if you want to get the texture of the text, you can use CoreLabel. This is useful when you want to draw text on a canvas or use it in a custom way.

```kv
<Label>:
    canvas:
        Color:
            rgba: 1, 1, 1, 1
        Rectangle:
            texture: self.texture
            size: self.texture_size
            pos: int(self.center_x - self.texture_size[0] / 2.), int(self.center_y - self.texture_size[1] / 2.)
```

```py
from kivy.core.text import Label as CoreLabel

my_label = CoreLabel()
my_label.text = 'hello'
# the label is usually not drawn until needed, so force it to draw.
my_label.refresh()
# Now access the texture of the label and use it wherever and
# however you may please.
hello_texture = my_label.texture
```

CoreLabel is a low-level class that provides access to the text rendering capabilities of Kivy. It allows you to create and manipulate text textures directly, which can be useful for custom drawing or when you need more control over how text is rendered in your application.

CoreLabel can be inited with these parameters:
https://github.com/kivy/kivy/blob/dc32205ac51ba5452eb904b2fd78cdafffd64ccd/kivy/core/text/__init__.py#L321



implement Text from Figma as CoreLabel and draw it on canvas, you can use the following code:

```kv
<CanvasText>:
    canvas:
        Color:
            rgba: self.color
        Rectangle:
            texture: self.texture
            size: self.texture_size
            pos: self.pos
```

but write as we done with canvas-py.