#!/usr/bin/env bash

echo "HOME: $HOME"
name="Student"
echo "User: $name"
num1=7
num2=5
echo "Sum: $((num1 + num2))"

if [ "$num1" -gt "$num2" ]; then
  echo "num1 больше num2"
else
  echo "num1 не больше num2"
fi

if [ -f lab15/myscript.sh ]; then
  echo "Файл существует"
else
  echo "Файл не найден"
fi
