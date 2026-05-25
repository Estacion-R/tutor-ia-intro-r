# Cómo usar la IA como tutor de R

> Guía práctica para alumnos del curso Intro al Procesamiento de Datos con R · Estación R

---

## ¿Qué es esto?

Te preparamos un **tutor virtual de R** especializado en el contenido del curso. Tenés tres formas de usarlo:

| Forma | Qué es | Para quién | Esfuerzo |
|---|---|---|---|
| **Chat del curso** | ShinyApp con login por email · usa Gemini | Durante el curso | Cero |
| **Templates** | Para copiar y pegar en cualquier IA gratis | Todos, post-curso también | Cero |
| **Tutor personalizado** | Configurás una vez en ChatGPT/Claude/Gemini | Los que quieran más | 2 min de setup |

---

## Chat del curso (ShinyApp)

La forma más simple. Mientras dure el curso vas a tener acceso a un chat dedicado, con un tutor de R que ya viene configurado con el contenido y el método pedagógico del curso.

**Cómo se usa:**

1. Entrá al link que te pasa el docente.
2. Logueate con el mismo email con el que te inscribiste.
3. Mandá tu consulta. El tutor está pensado para guiarte a resolver, no para darte la respuesta hecha.

**¿No sabés cómo arrancar la consulta?**

Arriba del chat vas a ver cuatro tarjetas: *Tengo un error*, *No entiendo un concepto*, *Quiero practicar*, *Mejorar mi código*. Tocá la que te corresponda y el chat se completa con una plantilla. Reemplazá los `[corchetes]` con tu información real antes de mandar.

### Cómo formular una buena pregunta

El tutor responde mejor cuando le das **contexto + objetivo + lo que probaste**. Estos tres ejemplos muestran la diferencia entre una pregunta que no llega a ningún lado y una que te ahorra 5 minutos de ida y vuelta.

**Ejemplo 1 · cuando tenés un error**

❌ Vaga:
> "No me anda el código"

✅ Útil:
> Pegué este código y me dio un error:
>
> ```r
> datos |> filter(edad > 30)
> ```
>
> Mensaje de error: `Error: object 'datos' not found`
>
> ¿Qué intenté hacer mal?

**Ejemplo 2 · cuando no entendés un concepto**

❌ Vaga:
> "Explicame mutate"

✅ Útil:
> No entiendo cuándo usar `mutate()` y cuándo `summarise()`. ¿Me das una explicación con un ejemplo simple usando datos sociales?

**Ejemplo 3 · cuando querés practicar**

❌ Vaga:
> "Dame un ejercicio"

✅ Útil:
> ¿Me podés dar un ejercicio para practicar `filter()` y `select()` usando datos sociales? Estoy aprendiendo recién, vimos hasta el módulo 3.

**La regla:** si tu pregunta cabe en menos de una línea, probablemente le falta contexto. Decile al tutor qué intentaste, qué esperabas y qué pasó.

**Qué guardamos y por cuánto tiempo:**

Las conversaciones (tu mensaje y la respuesta del tutor) se guardan **90 días** después de terminado el curso, asociadas a tu email. Las usamos para:

- Mejorar el tutor en futuras cohortes (qué consultas son frecuentes, dónde se traba la gente).
- Detectar problemas técnicos.
- Acompañar tu seguimiento durante el curso (si el docente nota que no estás usando el tutor o que estás trabado en algo, puede preguntarte).

**Importante:** no compartas datos personales sensibles en el chat (DNI, datos bancarios, información confidencial de terceros). El chat no es el lugar para eso.

Pasados los 90 días, las conversaciones se borran. Si querés que se borren antes, escribí a `estacionr.com@gmail.com`.

---

## Para usar fuera del chat del curso (templates y tutor personalizado)

Si querés seguir usando el tutor después del curso, o si en algún momento el chat no está disponible, podés usar las mismas instrucciones del tutor en cualquier IA gratis (ChatGPT, Claude, Gemini).

---

## Nivel Rápido: Templates

Abrí el archivo **"Templates para copiar y pegar"** y elegí el que necesites:

1. **Tengo un error** → copiá el template, pegá tu código y el error
2. **No entiendo un concepto** → copiá el template, completá el concepto
3. **Quiero practicar** → copiá el template, indicá qué funciones aprendiste
4. **Quiero mejorar mi código** → copiá el template, pegá tu código
5. **Ayuda con el TP** → copiá el template, describí la consigna

Esto funciona en cualquier chat de IA sin configurar nada.

---

## Nivel Avanzado: Tutor personalizado

Esto configura la IA para que SIEMPRE te responda como tutor de R, sin tener que copiar un template cada vez.

### En ChatGPT (gratis)

1. Abrí ChatGPT → hacé clic en tu foto de perfil (arriba a la derecha)
2. Andá a **"Personalizar ChatGPT"** (o "Customize ChatGPT")
3. En el segundo campo ("¿Cómo te gustaría que respondiera ChatGPT?"), pegá el contenido del archivo **"tutor-general.md"**
4. Guardá

A partir de ahora, cada conversación nueva va a tener ese contexto.

### En Claude (gratis)

1. Abrí Claude → en la barra izquierda, hacé clic en **"Proyectos"**
2. Creá un proyecto nuevo (ej: "Curso R")
3. En las **instrucciones del proyecto**, pegá el contenido de **"tutor-general.md"**
4. Iniciá conversaciones dentro de ese proyecto

### En Gemini (gratis)

1. Abrí Gemini → hacé clic en **"Gems"** en el menú lateral
2. Creá una Gem nueva (ej: "Tutor R")
3. En las instrucciones, pegá el contenido de **"tutor-general.md"**
4. Usá esa Gem para tus preguntas de R

---

## Reglas de oro

1. **Siempre pegá el código Y el error completo.** Sin eso, la IA adivina.
2. **Pedí explicaciones, no soluciones.** "¿Qué significa este error?" es mejor que "arreglame el código".
3. **Verificá siempre el código que te da.** Las IAs inventan funciones que no existen. Si una función no la viste en clase, preguntá antes de usarla.
4. **Un tema por conversación.** Después de 8-10 mensajes, la IA empieza a "olvidar". Si cambiás de tema, abrí un chat nuevo.
5. **No le pidas que te haga el TP.** Sí podés pedirle que te ayude a pensar los pasos.

---

## Qué NO hacer

- No pedir "haceme el TP" (no aprendés, y el docente se da cuenta)
- No confiar ciegamente en el código generado (testear siempre en RStudio)
- No usar funciones que no viste en clase sin entenderlas primero
- No pedir soluciones en base R si en el curso usamos tidyverse (puede confundirte)

---

## Prompts especializados (opcional)

Si querés un tutor más preciso para un tema puntual, tenemos prompts adicionales:

- **debugger-errores.md** → Especializado en entender mensajes de error
- **tutor-ggplot2.md** → Especializado en hacer gráficos con ggplot2

Se usan igual que el tutor general: pegá el contenido en las instrucciones de tu chat.

---

*Estación R — estacion-r.com*
